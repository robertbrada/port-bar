//
//  PortMenu.swift
//  PortBar
//

import AppKit

/// Builds the status item's menu from the current port list.
///
/// Titles are **plain strings, never `attributedTitle`**. An attributed title
/// with explicit colours does not invert when AppKit highlights the row, so a
/// two-tone "port in grey, name in white" line turns into dark text on the
/// accent colour the moment you hover it. The port therefore leads the plain
/// title instead, which keeps a column edge on the left without fighting the
/// highlight.
@MainActor
enum PortMenu {

    static func populate(_ menu: NSMenu, monitor: PortMonitor, target: AppDelegate) {
        menu.removeAllItems()

        menu.addItem(.sectionHeader(title: listHeading(monitor)))

        let entries = monitor.visible
        if entries.isEmpty {
            menu.addItem(disabled(monitor.showsSystemPorts
                                  ? "Nothing is listening on a TCP port"
                                  : "No dev servers running"))
        } else {
            // Deliberately flat and sorted by port, not split into
            // Ports/Docker sections: port order is how you scan when hunting
            // for a specific number, and a Docker row already announces itself
            // with a whale and a container name.
            for entry in entries {
                menu.addItem(portItem(entry, target: target))
            }
        }

        if let error = monitor.lastError {
            menu.addItem(.separator())
            menu.addItem(disabled(error))
        }

        menu.addItem(.separator())

        // Everything that isn't a port lives behind one row. No separator
        // between these two: they're both the app talking about itself, where
        // the separator above divides the app from the ports it found.
        menu.addItem(settingsItem(monitor: monitor, target: target))

        let quit = item("Quit PortBar", #selector(AppDelegate.quit(_:)), target)
        quit.keyEquivalent = "q"
        menu.addItem(quit)
    }

    /// The list's heading, and **the one place the filter admits what it's
    /// holding back**. The count used to ride on the *Show System Ports* label,
    /// which worked only while that item was on the top level; it's a rare
    /// control that was costing a permanent row, so it moved into *Settings*
    /// and the count moved here. The header was carrying no information at all,
    /// so this is free — and the rule it exists for is that the number must be
    /// visible without interaction, not that it must sit on the control.
    private static func listHeading(_ monitor: PortMonitor) -> String {
        guard !monitor.showsSystemPorts, monitor.systemCount > 0 else { return "Listening Ports" }
        return "Listening Ports · \(monitor.systemCount) hidden"
    }

    /// *Settings* — the whole footer, folded into one row.
    ///
    /// It held four rows and two separators under a list that is often only
    /// four rows itself, so the app's own chrome was half of what opening
    /// PortBar showed you. None of it is something you touch while reading the
    /// list: the sort order and *Launch at Login* are set once, and the system
    /// filter is for the rare "show me everything" moment — 34 things listen on
    /// a normal Mac and about six are yours.
    ///
    /// *Sort By* is a **section inside this menu, not a submenu of it**. Nesting
    /// it would put a routine choice three levels deep, and a section header
    /// names the group just as well for free.
    private static func settingsItem(monitor: PortMonitor, target: AppDelegate) -> NSMenuItem {
        let item = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
        item.isEnabled = true

        let settings = NSMenu()
        settings.autoenablesItems = false

        // Radio-style choices rather than one item that cycles: a cycling item
        // can only ever name *one* of the two, so it can't say which you're on
        // without spelling out both.
        settings.addItem(.sectionHeader(title: "Sort By"))
        for order in SortOrder.allCases {
            let choice = self.item(order.title, #selector(AppDelegate.setSortOrder(_:)), target)
            choice.representedObject = order.rawValue
            choice.state = monitor.sortOrder == order ? .on : .off
            settings.addItem(choice)
        }

        settings.addItem(.separator())

        // The count stays on this label too. The header says how many are
        // hidden; the control says how many it would reveal, which is the same
        // number and the thing you want to see with your hand already on it.
        let systemPorts = self.item(monitor.systemCount > 0
                                    ? "Show System Ports (\(monitor.systemCount))"
                                    : "Show System Ports",
                                    #selector(AppDelegate.toggleSystemPorts(_:)), target)
        systemPorts.state = monitor.showsSystemPorts ? .on : .off
        settings.addItem(systemPorts)

        let launch = self.item("Launch at Login",
                               #selector(AppDelegate.toggleLaunchAtLogin(_:)), target)
        launch.state = LaunchAtLogin.isEnabled ? .on : .off
        settings.addItem(launch)

        item.submenu = settings
        return item
    }

    // MARK: - A port and its submenu

    private static func portItem(_ entry: PortEntry, target: AppDelegate) -> NSMenuItem {
        let title = entry.menuTitlePrefix + MenuText.fitted(entry.label, to: MenuText.rowLabelWidth)
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.image = icon(for: entry)
        item.isEnabled = true
        // An item with a submenu ignores its own action, so the row itself is
        // not clickable. That's the trade for hover-to-open: every action is one
        // hover and one click away, where the old panel needed a click to open
        // the `⋯` menu first.
        item.submenu = submenu(for: entry, target: target)
        return item
    }

    private static func submenu(for entry: PortEntry, target: AppDelegate) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        // Constant width, so the submenu always appears in the same place
        // relative to its row instead of resizing — and flipping sides — with
        // whatever its longest detail line happens to be.
        menu.minimumWidth = MenuText.submenuWidth

        // The first item must be something you can actually pick. This used to
        // open with the disabled `command · pid` line, so every submenu began
        // with a dead row that swallowed the keyboard's first Down and looked
        // like a bug. The detail moved to the bottom.
        if entry.isLikelyWeb {
            menu.addItem(action("Open in Browser",
                                #selector(AppDelegate.openInBrowser(_:)), entry, target))
            menu.addItem(action("Copy URL",
                                #selector(AppDelegate.copyAddress(_:)), entry, target))
        } else {
            // `localhost:5432` — what you'd paste into a database client.
            menu.addItem(action("Copy Address",
                                #selector(AppDelegate.copyAddress(_:)), entry, target))
        }

        menu.addItem(.separator())

        let logs = action(entry.logSource.actionTitle,
                          #selector(AppDelegate.viewLogs(_:)), entry, target)
        logs.isEnabled = entry.logSource.canShow
        menu.addItem(logs)

        if entry.cwd != nil {
            // A *new* shell in the project folder. This is not "show me the
            // logs" — it replaces the old "Reveal in Terminal", which claimed to
            // find the session already running and usually couldn't.
            menu.addItem(action("Open in Terminal",
                                #selector(AppDelegate.openInTerminal(_:)), entry, target))
            menu.addItem(action("Reveal in Finder",
                                #selector(AppDelegate.revealFolder(_:)), entry, target))
        }

        menu.addItem(.separator())
        menu.addItem(action("Stop", #selector(AppDelegate.stopProcess(_:)), entry, target))
        menu.addItem(action("Force Stop",
                            #selector(AppDelegate.forceStopProcess(_:)), entry, target))

        // Reference, not action — so it goes last, where a footer belongs. Each
        // value is wrapped rather than truncated: this is the one place the full
        // name is shown, so it must not be abbreviated a second time.
        menu.addItem(.separator())
        // The full label, but only when the row abbreviated it — the submenu is
        // the one place it's shown in full, so it's wrapped rather than cut. It
        // gets the whole width and no label of its own: it's the heading the
        // facts below belong to, and it's the same text the row already shows.
        if MenuText.fitted(entry.label, to: MenuText.rowLabelWidth) != entry.label {
            for line in MenuText.wrapped(entry.label, to: MenuText.submenuTextWidth) {
                menu.addItem(heading(line))
            }
        }
        for fact in entry.detailFacts {
            for item in factItems(fact.label, fact.value) { menu.addItem(item) }
        }
        return menu
    }

    // MARK: - Item plumbing

    private static func item(_ title: String, _ selector: Selector,
                             _ target: AppDelegate) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = target
        item.isEnabled = true
        return item
    }

    private static func action(_ title: String, _ selector: Selector,
                               _ entry: PortEntry, _ target: AppDelegate) -> NSMenuItem {
        let item = self.item(title, selector, target)
        item.representedObject = entry
        return item
    }

    /// One footer fact, as however many lines its value needs. The label sits on
    /// the first line only; continuations are indented to the value column.
    private static func factItems(_ label: String, _ value: String) -> [NSMenuItem] {
        let room = MenuText.submenuTextWidth - MenuText.detailValueColumn
        return MenuText.wrapped(value, to: room).enumerated().map { index, line in
            let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            item.isEnabled = false
            item.attributedTitle = MenuText.columned(index == 0 ? label : "", line)
            return item
        }
    }

    /// The full project name above the facts.
    private static func heading(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.attributedTitle = MenuText.unlabelled(title)
        return item
    }

    private static func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    /// Box every row's glyph is drawn in. Smaller than AppKit's usual 16 for a
    /// menu image, and deliberately smaller than the 13pt menu text: these are
    /// solid brand marks where an SF Symbol is a stroked outline, so at 16 they
    /// outweighed the text and the eye ran *down* the icon column instead of
    /// across the row. The glyphs identify a row; they don't label it.
    private static let iconSize: CGFloat = 11

    private static func icon(for entry: PortEntry) -> NSImage? {
        // `NSImage(named:)` hands back a *shared* instance, so resizing it
        // would resize every other use of that asset. Copy first.
        let source: NSImage? = if let name = entry.iconName {
            NSImage(named: name)
        } else {
            NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: iconSize, weight: .regular))
        }
        guard let image = source?.copy() as? NSImage else { return nil }
        image.isTemplate = true
        // 14, not 16. A brand glyph is a solid filled shape where an SF Symbol
        // is a stroked outline, so at a shared box size the logos read heavier
        // than the menu text beside them and pull the eye down the icon column
        // instead of across the row. A couple of points off settles them.
        image.size = NSSize(width: Self.iconSize, height: Self.iconSize)
        return image
    }
}
