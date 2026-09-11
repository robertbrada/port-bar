//
//  Preferences.swift
//  PortBar
//

import Foundation

/// How the list is ordered.
///
/// Two orders, because there are two ways people arrive at this menu. If you
/// already know the number you're hunting for, `port` is the only order that
/// lets you scan for it. If you're asking "what have I got running?" — the case
/// this app was built for, several agents having each started a server — then
/// grouping by what a thing *is* answers it faster than any number can.
enum SortOrder: String, CaseIterable {
    case port
    case technology

    /// Named after what you'd be looking for, not after the sort key. "Icon"
    /// would describe the mechanism; the user is grouping by what the service
    /// *is*, and the glyph is only how that's drawn.
    var title: String {
        switch self {
        case .port: "Port Number"
        case .technology: "Technology"
        }
    }
}

enum Preferences {
    private static let defaults = UserDefaults.standard

    static var showsSystemPorts: Bool {
        get { defaults.bool(forKey: "showsSystemPorts") }
        set { defaults.set(newValue, forKey: "showsSystemPorts") }
    }

    /// Defaults to `port` — an unfamiliar list is read by number, and it's the
    /// order `PortScanner` already returns.
    static var sortOrder: SortOrder {
        get { SortOrder(rawValue: defaults.string(forKey: "sortOrder") ?? "") ?? .port }
        set { defaults.set(newValue.rawValue, forKey: "sortOrder") }
    }
}
