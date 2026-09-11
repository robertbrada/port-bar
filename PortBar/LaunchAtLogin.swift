//
//  LaunchAtLogin.swift
//  PortBar
//

import Foundation
import ServiceManagement

enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func set(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            print("PortBar: launch-at-login \(enabled ? "register" : "unregister") failed: \(error)")
        }
    }
}
