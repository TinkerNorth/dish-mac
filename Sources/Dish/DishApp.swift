// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import AppKit
import DishCore
import DishCrashUpload
import DishEngine
import SwiftUI

@main
struct DishApp: App {

    @StateObject private var model = AppModel(
        lifecycle: appKitLifecycleSignals(workspace: NSWorkspace.shared.notificationCenter),
        appVersion: bundleVersion(Bundle.main),
        crashLog: CrashLog.standard(),
        crashUploader: SentryCrashUploader(dsn: crashReportingAddress(Bundle.main), appVersion: bundleVersion(Bundle.main))
    )
    @StateObject private var notifications = DishNotificationCenter()
    @StateObject private var failureNotifier = FailureNotifier()
    @StateObject private var moonlightNotifier = MoonlightNotifier()
    @StateObject private var updateNotifier = UpdateNotifier()
    @StateObject private var lidNotifier = LidNotifier()
    @StateObject private var navigation = NavigationStore(
        preferences: UiPreferenceStore(defaults: .standard),
        activateWindow: activateDish
    )
    @NSApplicationDelegateAdaptor private var delegate: DishAppDelegate
    @Environment(\.openWindow) private var openWindow
    private let licenseNotice = thirdPartyNotice(in: L10n.app.catalog.bundle)

    init() {
        // First, so a fault anywhere after this leaves a backtrace the user
        // can review and choose to send; nothing is transmitted.
        CrashHandler.install(log: CrashLog.standard())
        // `swift run` launches a bare binary with no .app bundle, so the
        // activation policy is set here for the window and the Dock icon.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        Window(L10n.app.appName, id: DishWindow.main) {
            ShellView(licenseNotice: licenseNotice)
                .preferredColorScheme(colorScheme(for: model.theme.state))
                .environmentObject(model)
                .environmentObject(navigation)
                .environmentObject(model.wifi)
                .environmentObject(model.moonlight)
                .environmentObject(model.settings)
                .environmentObject(model.theme)
                .environmentObject(model.background)
                .environmentObject(model.keepAwake)
                .environmentObject(model.updatePreferences)
                .environmentObject(model.updates)
                .environmentObject(model.crashReporting)
                .environmentObject(model.diagnostics)
                .environmentObject(model.diagnosticsLog)
                .environmentObject(model.inspector)
                .environmentObject(notifications)
                .environment(\.pasteboard, .system)
                .frame(minWidth: DishSize.windowMinWidth, minHeight: DishSize.windowMinHeight)
                .background(DishTheme.background.ignoresSafeArea())
                .onAppear(perform: bindNotifiers)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: DishSize.windowDefaultWidth, height: DishSize.windowDefaultHeight)
        .commands {
            ShellCommands(navigation: navigation, show: show)
        }

        MenuBarExtra {
            MenuBarMenu(show: show)
                .environmentObject(model)
        } label: {
            Image(systemName: "gamecontroller")
        }
    }

    private func bindNotifiers() {
        failureNotifier.bind(failures: model.failures.eraseToAnyPublisher(), center: notifications)
        moonlightNotifier.bind(events: model.moonlight.events.eraseToAnyPublisher(), center: notifications, quitApp: quitMoonlightApp)
        updateNotifier.bind(checker: model.updates, center: notifications)
        lidNotifier.bind(lidPausedStreaming: model.lidPausedStreaming, center: notifications)
        delegate.bind(background: model.background, announcer: BackgroundAnnouncer())
    }

    private func quitMoonlightApp(_ host: MoonlightHost) {
        model.quitMoonlightApp(host.id)
    }

    /// The window comes up, closed or not, on what was asked for.
    private func show(_ request: ExternalRequest) {
        openWindow(id: DishWindow.main)
        navigation.send(.external(request))
    }
}

/// Brings Dish forward, for a request from outside the window.
@MainActor
func activateDish() {
    NSApplication.shared.activate(ignoringOtherApps: true)
}

/// The scene id the menu bar opens.
enum DishWindow {
    static let main = "main"
}

/// The crash-reporting address `bundle.sh` wrote into the plist from the
/// release secret; nil for a bare `swift run` binary, a pull request or a
/// fork, which can then send nothing.
func crashReportingAddress(_ bundle: Bundle) -> String? {
    bundle.object(forInfoDictionaryKey: "DishSentryDSN") as? String
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
