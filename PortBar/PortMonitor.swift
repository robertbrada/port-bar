//
//  PortMonitor.swift
//  PortBar
//

import AppKit
import Foundation

/// The data behind the menu: what's listening, and the actions that change it.
///
/// Refreshes two ways, deliberately. `refreshNow()` is **synchronous**, for
/// `menuNeedsUpdate` — a menu can't await, and it must be correct the instant it
/// opens. The background poll is async and exists only to keep the menu-bar
/// count honest.
@MainActor
final class PortMonitor {
    private(set) var entries: [PortEntry] = []
    private(set) var lastError: String?

    /// Called whenever `entries` changes, so the status item can restate its
    /// count. The menu itself rebuilds on open and doesn't need telling.
    var onUpdate: (() -> Void)?

    var showsSystemPorts: Bool {
        get { Preferences.showsSystemPorts }
        set { Preferences.showsSystemPorts = newValue }
    }

    var sortOrder: SortOrder {
        get { Preferences.sortOrder }
        set { Preferences.sortOrder = newValue }
    }

    var visible: [PortEntry] {
        let shown = showsSystemPorts ? entries : entries.filter(\.isDev)
        switch sortOrder {
        case .port:
            // Already in port order — `PortScanner` sorts before returning.
            return shown
        case .technology:
            return shown.sorted { a, b in
                let (left, right) = (a.technologyKey, b.technologyKey)
                // Port breaks the tie, so a group's own rows keep the order
                // they'd have had and nothing shuffles between scans.
                return left == right ? a.port < b.port : left < right
            }
        }
    }

    /// How many rows the filter is holding back — shown on the toggle so the
    /// list never looks like it's hiding something silently.
    var systemCount: Int {
        entries.count - entries.filter(\.isDev).count
    }

    // MARK: - Refreshing

    /// Last known container names. Kept as a plain snapshot so a *synchronous*
    /// rebuild can still label Docker rows: `DockerPorts` is an actor and can't
    /// be read without awaiting, so a brand-new container shows as
    /// `com.docker.backend` until the next background tick.
    private var dockerNames: [Int: String] = [:]
    private var lastScan = Date.distantPast
    private var pollTask: Task<Void, Never>?

    /// A scan measures ~90ms, and the menu rescans on open anyway — so the
    /// background poll exists only for the menu-bar count and can be slow.
    /// 90ms every 15s is well under 1% of a core.
    private static let idleInterval: Duration = .seconds(15)
    /// Absorbs reopens: clicking the status item twice in a second shouldn't
    /// pay for two scans.
    private static let syncFloor: TimeInterval = 1

    func start() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshInBackground()
                try? await Task.sleep(for: Self.idleInterval)
            }
        }
    }

    /// Blocks the main thread for the duration of a scan. That is the right
    /// trade for a user-initiated menu open — a menu showing a stale port list
    /// is worse than one that takes 90ms to appear — but it is why the poll
    /// above does *not* use this.
    func refreshNow() {
        guard Date().timeIntervalSince(lastScan) > Self.syncFloor else { return }
        publish(PortScanner.scan())
    }

    private func refreshInBackground() async {
        let scanned = await Task.detached(priority: .utility) { PortScanner.scan() }.value
        let dockerPorts = Set(scanned.filter(\.isDockerProxy).map(\.port))
        if !dockerPorts.isEmpty {
            dockerNames = await DockerPorts.shared.names(forPorts: dockerPorts)
        }
        publish(scanned)
    }

    private func publish(_ scanned: [PortEntry]) {
        entries = scanned.map { entry in
            guard entry.isDockerProxy, let container = dockerNames[entry.port] else { return entry }
            return entry.withProjectName(container)
        }
        lastScan = Date()
        onUpdate?()
    }

    // MARK: - Actions

    /// SIGTERM by default so the process gets to close its socket and flush;
    /// `force` sends SIGKILL, for the ones that ignore a polite ask.
    func stop(_ entry: PortEntry, force: Bool = false) {
        guard kill(entry.pid, force ? SIGKILL : SIGTERM) == 0 else {
            lastError = errno == EPERM
                ? "Can't stop \(entry.command) — it belongs to root or another user."
                : "Couldn't stop pid \(entry.pid): \(String(cString: strerror(errno)))"
            return
        }
        lastError = nil
        // Picking a menu item closes the menu, so there's no row left to dim —
        // this just makes sure the count catches up once the socket is actually
        // released, which isn't instant.
        Task { [weak self] in
            for delay: Duration in [.milliseconds(400), .seconds(2)] {
                try? await Task.sleep(for: delay)
                await self?.refreshInBackground()
            }
        }
    }

    func open(_ entry: PortEntry) {
        let port = entry.port
        let url = entry.localURL
        // Off the main actor: searching for an existing tab is an Apple Event
        // into a browser that may have a hundred of them.
        Task.detached(priority: .userInitiated) {
            BrowserOpener.open(port: port, url: url)
        }
    }

    /// Off the main actor: this shells out to `osascript` (which walks every
    /// Terminal window) and sometimes to the Docker daemon.
    func viewLogs(_ entry: PortEntry) {
        let source = entry.logSource
        let port = entry.port
        Task { [weak self] in
            let failure = await Task.detached(priority: .userInitiated) {
                LogViewer.show(source, port: port)
            }.value
            self?.lastError = failure
        }
    }

    func copyAddress(_ entry: PortEntry) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.address, forType: .string)
    }

    /// Terminal.app specifically, not "the user's terminal" — LaunchServices has
    /// no query for that, and opening a *directory* is only reliably understood
    /// as "start a shell here" by Terminal itself.
    func openInTerminal(_ entry: PortEntry) {
        guard let cwd = entry.cwd else { return }
        NSWorkspace.shared.open(
            [URL(fileURLWithPath: cwd)],
            withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"),
            configuration: NSWorkspace.OpenConfiguration()
        )
    }

    func revealFolder(_ entry: PortEntry) {
        guard let cwd = entry.cwd else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: cwd)])
    }
}
