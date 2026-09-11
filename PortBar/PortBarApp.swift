//
//  PortBarApp.swift
//  PortBar
//

import SwiftUI

@main
struct PortBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // The app is a status item and a native menu, both owned by
        // AppDelegate. This empty scene only satisfies the `App` requirement.
        Settings { EmptyView() }
    }
}
