// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import SwiftUI
import AppKit

@main
struct DishApp: App {

    @StateObject private var model = AppModel()

    init() {
        // `swift run` launches us as a bare Mach-O binary with no .app bundle,
        // so NSApplication defaults to `.prohibited` activation policy and the
        // window is created invisibly. Force regular-app behaviour so the
        // window shows, a Dock icon appears, and the app responds to focus.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        WindowGroup("Dish") {
            MainView()
                .environmentObject(model)
                .environmentObject(model.wifi)
                .environmentObject(model.telemetry)
                .frame(minWidth: 520, minHeight: 640)
                .background(DishTheme.background.ignoresSafeArea())
                .preferredColorScheme(.dark)
        }
        .windowResizability(.contentMinSize)
    }
}
