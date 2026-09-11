//
//  Shell.swift
//  PortBar
//

import Foundation

/// Blocking subprocess helpers. Everything here is `nonisolated` — call it off
/// the main actor.
enum Shell {

    nonisolated static func run(_ path: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        // Tools here warn on stderr about things we didn't ask about (`lsof` on
        // directories it can't stat); none of it matters, and it must not be
        // left to fill a pipe nobody drains.
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        do { try process.run() } catch { return "" }
        // Drain before waiting: `lsof` output exceeds the 64K pipe buffer on a
        // busy machine, and `waitUntilExit()` would deadlock against it.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    @discardableResult
    nonisolated static func appleScript(_ source: String) -> String {
        run("/usr/bin/osascript", ["-e", source]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Single-quoted for `/bin/sh`, with embedded single quotes broken out.
    /// Paths come from `lsof`, so they can contain anything a filename can.
    nonisolated static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Escaped for an AppleScript string literal. A shell command nested inside
    /// one needs both this and `shellQuoted`.
    nonisolated static func appleScriptQuoted(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
