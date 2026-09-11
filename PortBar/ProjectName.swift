//
//  ProjectName.swift
//  PortBar
//

import Foundation

/// Works out what to *call* a port's service, from the directory its process
/// runs in.
///
/// `basename(cwd)` alone is not enough, and the failure is not theoretical: in a
/// monorepo a dev server started in `apps/web` is called "web", and one machine
/// can easily hold three separate projects that would all show exactly that.
/// The manifest one directory up says `@acme/web`, `@northwind/web`,
/// `@contoso/web` — which is the whole point of the app.
enum ProjectName {

    /// `nil` when nothing trustworthy could be derived, which the UI shows as
    /// the process's command name instead.
    nonisolated static func detect(cwd: String?) -> String? {
        guard let cwd, cwd != "/" else { return nil }

        // Manifests are only read inside the user's own home. A process running
        // from /Applications or /usr has no project, and we have no business
        // reading files out there on a timer.
        if cwd.hasPrefix(home + "/") {
            var directory = cwd
            for _ in 0..<maxLevels {
                // `$HOME` itself is never a project root, even though plenty of
                // dotfile setups leave a `.git` or a `package.json` in it.
                guard directory.hasPrefix(home + "/") else { break }
                if let name = manifestName(in: directory) { return name }
                if FileManager.default.fileExists(atPath: directory + "/.git") {
                    return (directory as NSString).lastPathComponent
                }
                let parent = (directory as NSString).deletingLastPathComponent
                if parent == directory { break }
                directory = parent
            }
        }
        return folderName(cwd)
    }

    private static let home = NSHomeDirectory()
    /// Deep enough for `repo/apps/web/.next/standalone`-shaped cwds, shallow
    /// enough that it can't wander far.
    private static let maxLevels = 8

    // MARK: - Manifests

    private nonisolated static func manifestName(in directory: String) -> String? {
        if let data = FileManager.default.contents(atPath: directory + "/package.json"),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let name = object["name"] as? String,
           !name.isEmpty {
            return name
        }
        if let text = try? String(contentsOfFile: directory + "/Cargo.toml", encoding: .utf8),
           let name = tomlName(in: text, tables: ["package"]) {
            return name
        }
        if let text = try? String(contentsOfFile: directory + "/pyproject.toml", encoding: .utf8),
           let name = tomlName(in: text, tables: ["project", "tool.poetry"]) {
            return name
        }
        if let text = try? String(contentsOfFile: directory + "/go.mod", encoding: .utf8) {
            for line in text.split(separator: "\n") where line.hasPrefix("module ") {
                let module = line.dropFirst("module ".count).trimmingCharacters(in: .whitespaces)
                if let last = module.split(separator: "/").last, !last.isEmpty {
                    return String(last)
                }
            }
        }
        return nil
    }

    /// Just enough TOML to find `name = "…"` inside a named table. A real parser
    /// would be a dependency, and this reads exactly one key.
    private nonisolated static func tomlName(in text: String, tables: [String]) -> String? {
        var table = ""
        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("["), line.hasSuffix("]") {
                table = String(line.dropFirst().dropLast())
                continue
            }
            guard tables.contains(table), let equals = line.firstIndex(of: "=") else { continue }
            // Compare the whole key, or `namespace = …` would match.
            guard line[..<equals].trimmingCharacters(in: .whitespaces) == "name" else { continue }
            let value = line[line.index(after: equals)...]
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if !value.isEmpty { return value }
        }
        return nil
    }

    // MARK: - Fallback

    /// The directory's own name — unless the directory is support plumbing,
    /// where the leaf is actively misleading. Docker runs from
    /// `~/Library/Containers/…/Data` ("Data") and a Gradle daemon from
    /// `~/.gradle/daemon/8.13` ("8.13"); falling back to the command name is
    /// more honest than either.
    private nonisolated static func folderName(_ cwd: String) -> String? {
        guard cwd != home, !cwd.hasPrefix(home + "/Library/") else { return nil }
        guard !cwd.split(separator: "/").contains(where: { $0.hasPrefix(".") }) else { return nil }
        let name = (cwd as NSString).lastPathComponent
        return name.isEmpty ? nil : name
    }
}
