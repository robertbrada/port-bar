//
//  PortScanner.swift
//  PortBar
//

import Foundation

/// Reads the live listening-port table by shelling out to `lsof` and `ps`.
///
/// Three process spawns, ~50ms total: `lsof` for the listening sockets, `ps` for
/// full command lines, and a second *batched* `lsof` for working directories.
/// The batching is the point — asking `lsof` for one PID's cwd at a time meant a
/// spawn per port, and this runs on a timer.
///
/// Everything here is `nonisolated` and blocking; call it off the main actor.
enum PortScanner {

    nonisolated static func scan() -> [PortEntry] {
        let sockets = listeningSockets()
        guard !sockets.isEmpty else { return [] }

        let pids = Array(Set(sockets.map(\.pid)))
        let commandLines = commandLines()
        let files = processFiles(of: pids)

        // Collapse to one row per port. A port appears once per file descriptor
        // and once per address family, and occasionally under two PIDs
        // (SO_REUSEPORT); the lowest PID wins so the row doesn't flip between
        // scans, and the all-interfaces flag is the union.
        // Memoised per cwd: several ports commonly share one process, and
        // several processes one directory, and each miss is a handful of file
        // reads walking up to the manifest.
        var projectNames: [String: String?] = [:]

        var byPort: [Int: PortEntry] = [:]
        for socket in sockets {
            let existing = byPort[socket.port]
            if let existing, existing.pid <= socket.pid {
                if socket.allInterfaces && !existing.bindsAllInterfaces {
                    byPort[socket.port] = existing.bindingAllInterfaces()
                }
                continue
            }
            let info = files[socket.pid]
            let cwd = info?.cwd == "/" ? nil : info?.cwd
            let projectName: String?
            if let cwd {
                if let memoised = projectNames[cwd] {
                    projectName = memoised
                } else {
                    projectName = ProjectName.detect(cwd: cwd)
                    projectNames[cwd] = projectName
                }
            } else {
                projectName = nil
            }

            byPort[socket.port] = PortEntry(
                port: socket.port,
                pid: socket.pid,
                command: socket.command,
                commandLine: commandLines[socket.pid] ?? socket.command,
                cwd: cwd,
                bindsAllInterfaces: socket.allInterfaces || (existing?.bindsAllInterfaces ?? false),
                logSource: logSource(command: socket.command, stdout: info?.stdout),
                projectName: projectName
            )
        }
        return byPort.values.sorted { $0.port < $1.port }
    }

    // MARK: - Listening sockets

    private struct Socket {
        let pid: Int32
        let command: String
        let port: Int
        let allInterfaces: Bool
    }

    /// `-F pcn` is lsof's machine-readable mode: one field per line, tagged by
    /// its first character. It's used instead of the columnar default because
    /// that one truncates the command name to 9 characters, which turns every
    /// interesting process into "Code\x20H" or "com.dock".
    private nonisolated static func listeningSockets() -> [Socket] {
        let output = Shell.run(lsofPath, ["-nP", "-iTCP", "-sTCP:LISTEN", "-F", "pcn"])
        var sockets: [Socket] = []
        var pid: Int32?
        var command = ""

        for line in output.split(separator: "\n") {
            guard let tag = line.first else { continue }
            let value = line.dropFirst()
            switch tag {
            case "p":
                pid = Int32(value)
                command = ""
            case "c":
                command = String(value)
            case "n":
                guard let pid, let address = parseAddress(value) else { continue }
                sockets.append(Socket(pid: pid, command: command,
                                      port: address.port, allInterfaces: address.allInterfaces))
            default:
                break
            }
        }
        return sockets
    }

    /// `*:8080`, `127.0.0.1:3000`, `[::1]:7679` → the port, and whether the bind
    /// is to every interface rather than just loopback.
    private nonisolated static func parseAddress(
        _ name: Substring
    ) -> (port: Int, allInterfaces: Bool)? {
        guard let colon = name.lastIndex(of: ":"),
              let port = Int(name[name.index(after: colon)...])
        else { return nil }
        return (port, name[..<colon] == "*")
    }

    // MARK: - Enrichment

    /// Full argv per PID. One `ps` for the whole process table is cheaper than
    /// filtering, and we need it for at most a few dozen PIDs anyway.
    private nonisolated static func commandLines() -> [Int32: String] {
        var lines: [Int32: String] = [:]
        for line in Shell.run("/bin/ps", ["-axo", "pid=,command="]).split(separator: "\n") {
            let trimmed = line.drop { $0 == " " }
            guard let space = trimmed.firstIndex(of: " "),
                  let pid = Int32(trimmed[..<space]) else { continue }
            lines[pid] = String(trimmed[trimmed.index(after: space)...])
                .trimmingCharacters(in: .whitespaces)
        }
        return lines
    }

    struct ProcFiles {
        var cwd: String?
        /// fd 1's `lsof` type and name — `("REG", "/…/preview.log")`,
        /// `("CHR", "/dev/ttys007")`, `("PIPE", "->0x…")`.
        var stdout: (type: String, name: String)?

        /// Explicit and `nonisolated`: the project defaults every declaration to
        /// MainActor isolation, including a synthesized memberwise init, and the
        /// scanner builds these off the main actor.
        nonisolated init() {}
    }

    /// Working directory *and* stdout in one call. Both come from the same
    /// per-process file table, so asking for `-d cwd,1` costs no more than
    /// asking for `cwd` alone did.
    private nonisolated static func processFiles(of pids: [Int32]) -> [Int32: ProcFiles] {
        guard !pids.isEmpty else { return [:] }
        let output = Shell.run(lsofPath, [
            "-a", "-d", "cwd,1", "-p", pids.map(String.init).joined(separator: ","),
            "-F", "pftn",
        ])
        var files: [Int32: ProcFiles] = [:]
        var pid: Int32?
        var fd = ""
        var type = ""
        for line in output.split(separator: "\n") {
            guard let tag = line.first else { continue }
            let value = line.dropFirst()
            switch tag {
            case "p": pid = Int32(value)
            case "f": fd = String(value)
            case "t": type = String(value)
            case "n":
                guard let pid else { continue }
                if fd == "cwd" {
                    files[pid, default: ProcFiles()].cwd = String(value)
                } else if fd == "1" {
                    files[pid, default: ProcFiles()].stdout = (type, String(value))
                }
            default:
                break
            }
        }
        return files
    }

    /// Classifies fd 1 into what "view logs" can honestly offer.
    private nonisolated static func logSource(
        command: String,
        stdout: (type: String, name: String)?
    ) -> LogSource {
        // Checked before fd 1, because the Docker proxy's own stdout is a pipe
        // into Docker Desktop and tells us nothing — the container's logs are
        // reachable through the daemon instead.
        if command.lowercased().hasPrefix("com.docker") { return .dockerPort }
        guard let stdout else { return .unavailable }
        switch stdout.type {
        case "REG":
            return .file(path: stdout.name)
        case "CHR" where stdout.name.hasPrefix("/dev/tty"):
            return .terminal(tty: stdout.name)
        default:
            // /dev/null, and pipes we have no way to follow.
            return .unavailable
        }
    }

    // MARK: - Subprocess

    private nonisolated static let lsofPath: String = {
        let candidates = ["/usr/sbin/lsof", "/usr/bin/lsof", "/opt/homebrew/bin/lsof"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
            ?? "/usr/sbin/lsof"
    }()
}

private extension PortEntry {
    // `nonisolated` because the scanner runs off the main actor, and the
    // project defaults every declaration to MainActor isolation.
    nonisolated func bindingAllInterfaces() -> PortEntry {
        PortEntry(port: port, pid: pid, command: command, commandLine: commandLine,
                  cwd: cwd, bindsAllInterfaces: true, logSource: logSource,
                  projectName: projectName)
    }
}
