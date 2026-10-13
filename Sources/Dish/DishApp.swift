// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import AppKit
import DishEngine
import SwiftUI

@main
struct DishApp: App {

    @StateObject private var model = AppModel(
        lifecycle: appKitLifecycleSignals(
            application: .default,
            workspace: NSWorkspace.shared.notificationCenter
        )
    )
    /// Process-scoped queue + renderer for `DishNotification` banners.
    /// Injected into the SwiftUI environment so any view + `AppModel` can
    /// publish via `center.add(...)`; the `NotificationOverlay` at the
    /// bottom of the window reads `visible` and renders the stack.
    @StateObject private var notifications = DishNotificationCenter()
    @StateObject private var failureNotifier = FailureNotifier()

    init() {
        // `swift run` launches us as a bare Mach-O binary with no .app bundle,
        // so NSApplication defaults to `.prohibited` activation policy and the
        // window is created invisibly. Force regular-app behaviour so the
        // window shows, a Dock icon appears, and the app responds to focus.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        WindowGroup(L10n.app.appName) {
            MainView()
                .environmentObject(model)
                .environmentObject(model.wifi)
                .environmentObject(model.settings)
                .environmentObject(notifications)
                .frame(minWidth: 520, minHeight: 640)
                .background(DishTheme.background.ignoresSafeArea())
                .preferredColorScheme(.dark)
                // The notification strip stacks at the bottom of the
                // window; sheets present above the main view tree so
                // the overlay continues to render under the sheet
                // without fighting it for the layer order.
                .overlay(alignment: .bottom) {
                    NotificationOverlay()
                        .environmentObject(notifications)
                }
                .onAppear {
                    failureNotifier.bind(model: model, center: notifications)
                }
        }
        .windowResizability(.contentMinSize)
    }
}
