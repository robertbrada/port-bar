//
//  LogViewer.swift
//  PortBar
//

import AppKit
import Foundation

/// Turns a `LogSource` into something on screen.
///
/// Only the streaming cases reach here now. Raising the terminal that already
/// holds a PTY's output was removed: it worked for Terminal.app and iTerm2,
/// which expose a tty per tab, and silently degraded to "activate the owning
/// app" for everything else — which looks like nothing happening when that app
/// is already frontmost. See `LogSource.terminal`.
///
/// Logs are shown in Terminal.app rather than in a pane inside the app, for one
/// hard reason and one soft one. Hard: a `MenuBarExtra` window dismisses itself
/// on focus loss, so an in-panel log view would vanish the moment you clicked
/// it — a real viewer needs a separate `NSWindow`, which is a bigger build than
/// this. Soft: Terminal already has scrollback, find, selection and copy, and
/// `tail -f` is exactly what a developer would have typed anyway.
enum LogViewer {

    /// Returns an error message on failure, `nil` on success.
    nonisolated static func show(_ source: LogSource, port: Int) -> String? {
        switch source {
        case .file(let path):
            runInTerminal("tail -n 200 -f \(Shell.shellQuoted(path))", port: port)
            return nil

        case .dockerPort:
            guard let dockerPath else {
                return "Docker's CLI isn't installed where PortBar can find it."
            }
            guard let container = dockerContainer(publishing: port, dockerPath: dockerPath) else {
                return "No running container publishes port \(port)."
            }
            runInTerminal("\(Shell.shellQuoted(dockerPath)) logs -f --tail 200 \(Shell.shellQuoted(container))",
                          port: port)
            return nil

        case .terminal:
            // Unreachable from the menu — the item is disabled — but the case
            // must be handled, and this is the truth about it.
            return "Those logs only exist in the terminal window that started the process."

        case .unavailable:
            return "This process discards its output — there are no logs to show."
        }
    }

    // MARK: - Streaming into Terminal.app

    /// Find-or-create, never plain create. `do script` with no `in` clause
    /// always opens a *new* window, so clicking the log glyph twice used to
    /// leave two windows tailing the same file.
    ///
    /// The tab is stamped with a per-port custom title on creation, and that
    /// title is how it's found again — it survives PortBar restarts, and it
    /// doubles as a readable window title. If the tab is still there but its
    /// command has exited (the user hit ⌃C), the command is re-run **in that
    /// tab** rather than in a new window; `busy` is Terminal's own "is something
    /// running here" flag.
    private nonisolated static func runInTerminal(_ command: String, port: Int) {
        let script = Shell.appleScriptQuoted(command)
        let title = Shell.appleScriptQuoted(tabTitle(port: port))
        Shell.appleScript("""
        tell application "Terminal"
            activate
            repeat with w in windows
                repeat with t in tabs of w
                    -- `custom title` throws rather than returning empty on a tab
                    -- that never had one set, so every read needs the guard.
                    try
                        if custom title of t is "\(title)" then
                            if not busy of t then do script "\(script)" in t
                            set frontmost of w to true
                            set selected of t to true
                            return "reused"
                        end if
                    end try
                end repeat
            end repeat
            set fresh to do script "\(script)"
            set custom title of fresh to "\(title)"
            return "created"
        end tell
        """)
    }

    private nonisolated static func tabTitle(port: Int) -> String {
        "PortBar: \(port)"
    }

    // MARK: - Docker

    private nonisolated static var dockerPath: String? { DockerPorts.cliPath }

    /// Looked up fresh on every click rather than read from `DockerPorts`'s
    /// cache: that cache exists to label rows cheaply, but someone opening logs
    /// wants the container that is running *now*.
    private nonisolated static func dockerContainer(publishing port: Int,
                                                    dockerPath: String) -> String? {
        let output = Shell.run(dockerPath, ["ps", "--format", "{{.Names}}\t{{.Ports}}"])
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2 else { continue }
            // "0.0.0.0:5432->5432/tcp, [::]:5432->5432/tcp" — the host port is
            // the one before the arrow.
            if parts[1].contains(":\(port)->") { return String(parts[0]) }
        }
        return nil
    }

}
