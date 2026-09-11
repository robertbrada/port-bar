//
//  AppDelegate.swift
//  PortBar
//

import AppKit

/// Owns the status item and the menu. There is no window and no SwiftUI view in
/// the running app.
///
/// The menu is a real `NSMenu`, which is the whole point: hover-opens-submenu,
/// arrow-key navigation, type-to-select, edge flipping and accessibility are all
/// AppKit's, not ours. The previous SwiftUI panel had to hand-roll hover
/// highlighting, its own separators, an exact pixel height and a hit-target for
/// a `⋯` button, and still couldn't open a submenu on hover.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let monitor = PortMonitor()
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        menu.delegate = self
        // We decide what's enabled — notably the "No Logs Available" item, which
        // AppKit's auto-enabling would happily re-enable for us.
        menu.autoenablesItems = false

        setUpStatusItem()
        monitor.onUpdate = { [weak self] in self?.updateStatusItemTitle() }
        monitor.start()
    }

    // MARK: - Status item

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = Self.menuBarIcon()
            button.imagePosition = .imageLeading
            // Tabular figures, so the width doesn't jitter as the count changes
            // and shove every icon to its right.
            button.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        }
        // Handing the menu to the status item is what buys native click,
        // click-and-drag-to-select, and highlight-while-open behaviour.
        statusItem.menu = menu
        updateStatusItemTitle()
    }

    private static func menuBarIcon() -> NSImage? {
        let image = NSImage(systemSymbolName: "network", accessibilityDescription: "PortBar")?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        image?.isTemplate = true
        return image
    }

    private func updateStatusItemTitle() {
        statusItem?.button?.title = " \(monitor.visible.count)"
    }

    // MARK: - NSMenuDelegate

    /// Called immediately before the menu is shown, every time. Rebuilding here
    /// is the canonical pattern for a dynamic menu, and it means nothing has to
    /// keep a live view in sync — there is no view.
    func menuNeedsUpdate(_ menu: NSMenu) {
        monitor.refreshNow()
        PortMenu.populate(menu, monitor: monitor, target: self)
    }

    // MARK: - Actions
    //
    // One selector per action; the row's `PortEntry` rides along on the item's
    // `representedObject`, which is how a menu passes context without a closure.

    private func entry(from sender: Any?) -> PortEntry? {
        (sender as? NSMenuItem)?.representedObject as? PortEntry
    }

    @objc func openInBrowser(_ sender: Any?) {
        guard let entry = entry(from: sender) else { return }
        monitor.open(entry)
    }

    @objc func copyAddress(_ sender: Any?) {
        guard let entry = entry(from: sender) else { return }
        monitor.copyAddress(entry)
    }

    @objc func viewLogs(_ sender: Any?) {
        guard let entry = entry(from: sender) else { return }
        monitor.viewLogs(entry)
    }

    @objc func openInTerminal(_ sender: Any?) {
        guard let entry = entry(from: sender) else { return }
        monitor.openInTerminal(entry)
    }

    @objc func revealFolder(_ sender: Any?) {
        guard let entry = entry(from: sender) else { return }
        monitor.revealFolder(entry)
    }

    @objc func stopProcess(_ sender: Any?) {
        guard let entry = entry(from: sender) else { return }
        monitor.stop(entry)
    }

    @objc func forceStopProcess(_ sender: Any?) {
        guard let entry = entry(from: sender) else { return }
        monitor.stop(entry, force: true)
    }

    /// The chosen order rides along as the `SortOrder`'s raw value — menu items
    /// carry `PortEntry`s the same way everywhere else in this file.
    @objc func setSortOrder(_ sender: Any?) {
        guard let raw = (sender as? NSMenuItem)?.representedObject as? String,
              let order = SortOrder(rawValue: raw), order != monitor.sortOrder
        else { return }
        monitor.sortOrder = order
        // Same reason as the toggles below: picking this closes the menu, so
        // without a reopen you'd never see the list you just reordered.
        reopenMenu()
    }

    @objc func toggleSystemPorts(_ sender: Any?) {
        monitor.showsSystemPorts.toggle()
        updateStatusItemTitle()
        // This toggle changes what the menu *contains*, and AppKit dismisses a
        // menu the moment an item is picked — so without this you'd have to
        // reopen it to see the effect of your own click. Re-opening is the only
        // lever available: an `NSMenuItem` can't decline to dismiss, and
        // rebuilding a menu AppKit is still tracking is not safe.
        reopenMenu()
    }

    /// Deferred to the next run-loop turn so the current menu has finished
    /// dismissing; clicking the button again pops it, and `menuNeedsUpdate`
    /// rebuilds it with the new setting.
    private func reopenMenu() {
        DispatchQueue.main.async { [weak self] in
            self?.statusItem?.button?.performClick(nil)
        }
    }

    @objc func toggleLaunchAtLogin(_ sender: Any?) {
        LaunchAtLogin.set(!LaunchAtLogin.isEnabled)
        // Same reason as above: the checkmark is the only feedback this has, and
        // it's on an item you just made disappear.
        reopenMenu()
    }

    @objc func quit(_ sender: Any?) {
        NSApp.terminate(nil)
    }
}
