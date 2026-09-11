//
//  BrowserOpener.swift
//  PortBar
//

import AppKit
import Foundation

/// Opens `http://localhost:<port>` in the default browser, **reusing a tab that
/// already has that port open** instead of stacking up another duplicate.
///
/// Six localhost tabs (three of them on port 3000) had accumulated on the
/// author's machine before this existed — a menu-bar app you click to check on
/// a dev server shouldn't leave a trail behind it.
///
/// Only browsers that expose their tabs to AppleScript can be searched. Firefox
/// exposes nothing, so it — and any browser we don't recognise — falls through
/// to `NSWorkspace.open`, which is the old behaviour.
enum BrowserOpener {

    nonisolated static func open(port: Int, url: URL) {
        if let dialect = defaultBrowser(), focusExistingTab(port: port, in: dialect) { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Which browser, and how it talks

    /// The three tab-scripting dialects in circulation. They differ in both the
    /// containment hierarchy and the verb used to reveal a tab, so each needs
    /// its own script.
    private enum Dialect {
        /// Windows contain *spaces* which contain tabs, and revealing one means
        /// `focus` on the space then `select` on the tab. (`focus` is a space
        /// command in Arc's dictionary, not a tab one — a tab only understands
        /// `select`.)
        case arc(bundleID: String)
        /// `set current tab of window`.
        case safari(bundleID: String)
        /// `set active tab index of window` — shared by Chrome, Brave, Edge,
        /// Vivaldi and Opera, which all ship the same scripting dictionary.
        case chromium(bundleID: String)

        var bundleID: String {
            switch self {
            case .arc(let id), .safari(let id), .chromium(let id): id
            }
        }
    }

    private nonisolated static func defaultBrowser() -> Dialect? {
        guard let probe = URL(string: "http://localhost"),
              let appURL = NSWorkspace.shared.urlForApplication(toOpen: probe),
              let bundleID = Bundle(url: appURL)?.bundleIdentifier?.lowercased()
        else { return nil }

        // Never script a browser that isn't already running: the Apple Event
        // would launch it, which is slower and ruder than just opening the URL.
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
        else { return nil }

        switch bundleID {
        case "company.thebrowser.browser", "company.thebrowser.dia":
            return .arc(bundleID: bundleID)
        case "com.apple.safari", "com.apple.safaritechnologypreview":
            return .safari(bundleID: bundleID)
        case let id where id.hasPrefix("com.google.chrome"),
             let id where id.hasPrefix("com.brave.browser"),
             let id where id.hasPrefix("com.microsoft.edgemac"),
             let id where id.hasPrefix("com.vivaldi."),
             let id where id.hasPrefix("com.operasoftware."):
            return .chromium(bundleID: bundleID)
        default:
            // Firefox and friends expose no tab scripting at all.
            return nil
        }
    }

    // MARK: - Matching

    /// AppleScript booleans over a variable `u` holding a tab's URL.
    ///
    /// Split in two because a port can have several tabs open on it — 3000 had
    /// `/`, `/debug/articles` and `/inbox` — and the root is the one you almost
    /// always mean when you click the row. `root` wins outright; `any` is the
    /// consolation prize, taken only if no root tab exists.
    ///
    /// Prefix matching is deliberately anchored on a trailing slash *or* exact
    /// equality: a bare `starts with "http://localhost:3000"` would also match
    /// port 30001.
    private nonisolated static func predicates(port: Int) -> (root: String, any: String) {
        let hosts = ["http://localhost:\(port)", "http://127.0.0.1:\(port)"]
        let root = hosts
            .flatMap { ["u is \"\($0)\"", "u is \"\($0)/\""] }
            .joined(separator: " or ")
        let any = hosts
            .flatMap { ["u is \"\($0)\"", "u starts with \"\($0)/\""] }
            .joined(separator: " or ")
        return (root, any)
    }

    // MARK: - Scripts

    private nonisolated static func focusExistingTab(port: Int, in dialect: Dialect) -> Bool {
        let (root, any) = predicates(port: port)
        let script = switch dialect {
        case .arc(let id): arcScript(bundleID: id, root: root, any: any)
        case .safari(let id): safariScript(bundleID: id, root: root, any: any)
        case .chromium(let id): chromiumScript(bundleID: id, root: root, any: any)
        }
        return Shell.appleScript(script) == "ok"
    }

    // Each script does the whole search in one Apple Event round trip. Pulling
    // every tab's URL across to Swift and deciding here would be one event per
    // tab, and the author's Arc has well over seventy of them.
    //
    // The `try` blocks matter: a loading or blank tab returns `missing value`
    // for its URL, and comparing that to text raises rather than being false.

    private nonisolated static func arcScript(bundleID: String, root: String, any: String) -> String {
        """
        tell application id "\(bundleID)"
            set bw to 0
            set bs to 0
            set bt to 0
            repeat with wi from 1 to (count of windows)
                repeat with si from 1 to (count of spaces of window wi)
                    repeat with ti from 1 to (count of tabs of space si of window wi)
                        try
                            set u to URL of tab ti of space si of window wi
                            if \(root) then
                                tell space si of window wi to focus
                                tell tab ti of space si of window wi to select
                                activate
                                return "ok"
                            else if (\(any)) and bw is 0 then
                                set bw to wi
                                set bs to si
                                set bt to ti
                            end if
                        end try
                    end repeat
                end repeat
            end repeat
            if bw > 0 then
                tell space bs of window bw to focus
                tell tab bt of space bs of window bw to select
                activate
                return "ok"
            end if
        end tell
        return "no"
        """
    }

    private nonisolated static func safariScript(bundleID: String, root: String, any: String) -> String {
        """
        tell application id "\(bundleID)"
            set bw to 0
            set bt to 0
            repeat with wi from 1 to (count of windows)
                repeat with ti from 1 to (count of tabs of window wi)
                    try
                        set u to URL of tab ti of window wi
                        if \(root) then
                            set current tab of window wi to tab ti of window wi
                            set index of window wi to 1
                            activate
                            return "ok"
                        else if (\(any)) and bw is 0 then
                            set bw to wi
                            set bt to ti
                        end if
                    end try
                end repeat
            end repeat
            if bw > 0 then
                set current tab of window bw to tab bt of window bw
                set index of window bw to 1
                activate
                return "ok"
            end if
        end tell
        return "no"
        """
    }

    private nonisolated static func chromiumScript(bundleID: String, root: String, any: String) -> String {
        """
        tell application id "\(bundleID)"
            set bw to 0
            set bt to 0
            repeat with wi from 1 to (count of windows)
                repeat with ti from 1 to (count of tabs of window wi)
                    try
                        set u to URL of tab ti of window wi
                        if \(root) then
                            set active tab index of window wi to ti
                            set index of window wi to 1
                            activate
                            return "ok"
                        else if (\(any)) and bw is 0 then
                            set bw to wi
                            set bt to ti
                        end if
                    end try
                end repeat
            end repeat
            if bw > 0 then
                set active tab index of window bw to bt
                set index of window bw to 1
                activate
                return "ok"
            end if
        end tell
        return "no"
        """
    }
}
