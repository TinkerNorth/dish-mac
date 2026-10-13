// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import AppKit
import DishCore
import DishEngine
import SwiftUI

@main
struct DishApp: App {

    @StateObject private var model = AppModel(
        lifecycle: appKitLifecycleSignals(
            application: .default,
            workspace: NSWorkspace.shared.notificationCenter
        ),
        appVersion: bundleVersion(Bundle.main)
    )
    @StateObject private var notifications = DishNotificationCenter()
    @StateObject private var failureNotifier = FailureNotifier()
    @StateObject private var updateNotifier = UpdateNotifier()
    @NSApplicationDelegateAdaptor private var delegate: DishAppDelegate
    @Environment(\.openWindow) private var openWindow

    init() {
        // `swift run` launches a bare binary with no .app bundle, so the
        // activation policy is set here for the window and the Dock icon.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        Window(L10n.app.appName, id: DishWindow.main) {
            MainView()
                .preferredColorScheme(colorScheme(for: model.theme.state))
                .environmentObject(model)
                .environmentObject(model.wifi)
                .environmentObject(model.settings)
                .environmentObject(model.theme)
                .environmentObject(model.background)
                .environmentObject(model.keepAwake)
                .environmentObject(model.updatePreferences)
                .environmentObject(model.updates)
                .environmentObject(notifications)
                .frame(minWidth: 520, minHeight: 640)
                .background(DishTheme.background.ignoresSafeArea())
                .overlay(alignment: .bottom) {
                    NotificationOverlay()
                        .environmentObject(notifications)
                }
                .onAppear {
                    failureNotifier.bind(model: model, center: notifications)
                    updateNotifier.bind(checker: model.updates, center: notifications)
                    delegate.bind(background: model.background, announcer: BackgroundAnnouncer())
                }
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 560, height: 700)

        MenuBarExtra {
            MenuBarMenu(showWindow: showMainWindow)
                .environmentObject(model)
        } label: {
            Image(systemName: "gamecontroller")
        }
    }

    private func showMainWindow() {
        openWindow(id: DishWindow.main)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

/// The scene ids the menu bar reopens.
enum DishWindow {
    static let main = "main"
}

/// The running build as the bundle reports it; a bare `swift run` binary has
/// no plist and reads as the zero version, which no manifest can be older than.
func bundleVersion(_ bundle: Bundle) -> String {
    let short = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    return isValidVersion(short) ? short : "0.0.0"
}

/// The close-to-background rule at the AppKit seam: with the preference on,
/// closing the last window leaves Dish running behind the menu-bar item, and
/// the first time it says so.
final class DishAppDelegate: NSObject, NSApplicationDelegate {
    private var background: BackgroundPreferenceStore?
    private var announcer: (any BackgroundAnnouncing)?

    @MainActor
    func bind(background: BackgroundPreferenceStore, announcer: any BackgroundAnnouncing) {
        self.background = background
        self.announcer = announcer
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        MainActor.assumeIsolated {
            guard let background else { return true }
            let action = decideWindowCloseAction(backgroundEnabled: background.state.runInBackground, trayAvailable: true)
            if shouldAnnounceBackground(action, alreadyAnnounced: background.state.noticeShown) {
                announcer?.announce()
                background.setNoticeShown(true)
            }
            return action == .quit
        }
    }
}
