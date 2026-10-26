// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import DishEngine
import SwiftUI

struct AppearanceSection: View {
    @EnvironmentObject var model: AppModel
    let state: SettingsPageState
    private let words = L10n.app

    var body: some View {
        SettingsSection(title: words.appearanceSection) {
            PickerRow(title: words.theme, detail: words.themeDetail) {
                Picker("", selection: Binding(get: { state.theme }, set: model.setThemeMode)) {
                    ForEach(ThemeMode.allCases, id: \.self) { mode in
                        Text(themeModeText(mode)).tag(mode)
                    }
                }
            }
        }
    }
}

struct ForwardedFeaturesSection: View {
    @EnvironmentObject var model: AppModel
    let state: SettingsPageState
    private let words = L10n.app

    var body: some View {
        SettingsSection(title: words.forwardedFeaturesSection) {
            ToggleRow(
                title: words.rumble,
                detail: words.rumbleDetail,
                isOn: Binding(get: { state.rumble }, set: model.setRumbleForwarded)
            )
            ToggleRow(
                title: words.touchpad,
                detail: words.touchpadDetail,
                isOn: Binding(get: { state.touchpad }, set: model.setTouchpadForwarded)
            )
            PickerRow(title: words.lightBar, detail: words.lightbarDetail) {
                Picker("", selection: Binding(get: { state.lightbar }, set: model.setLightbarMode)) {
                    ForEach(LightbarMode.allCases) { mode in
                        Text(lightbarModeText(mode)).tag(mode)
                    }
                }
            }
            SettingsFootnote(text: words.featuresFootnote)
        }
    }
}

struct ControllerTuningSection: View {
    @EnvironmentObject var model: AppModel
    let state: SettingsPageState
    private let words = L10n.app

    var body: some View {
        SettingsSection(title: words.controllerTuningSection) {
            ToggleRow(
                title: words.motionGyro,
                detail: words.motionDetail,
                isOn: Binding(get: { state.motion }, set: model.setMotionForwarded)
            )
        }
    }
}

struct WindowSection: View {
    @EnvironmentObject var model: AppModel
    let state: SettingsPageState
    private let words = L10n.app

    var body: some View {
        SettingsSection(title: words.windowSection) {
            ToggleRow(
                title: words.keepRunningInBackground,
                detail: words.keepRunningDetail,
                isOn: Binding(get: { state.runInBackground }, set: model.setRunInBackground)
            )
        }
    }
}

struct PowerSection: View {
    @EnvironmentObject var model: AppModel
    let state: SettingsPageState
    private let words = L10n.app

    var body: some View {
        SettingsSection(title: words.powerSection) {
            PickerRow(title: words.keepComputerAwake, detail: words.keepAwakeDetail) {
                Picker("", selection: Binding(get: { state.keepAwake.mode }, set: model.setKeepAwakeMode)) {
                    ForEach(KeepAwakeMode.allCases, id: \.self) { mode in
                        Text(keepAwakeModeText(mode)).tag(mode)
                    }
                }
            }
            if state.showsIdleTimeout {
                StepperRow(
                    title: words.letGoAfterStillness,
                    value: Binding(get: { state.keepAwake.idleTimeoutMinutes }, set: model.setIdleTimeoutMinutes),
                    range: KeepAwakeLimits.minTimeoutMinutes ... KeepAwakeLimits.maxTimeoutMinutes,
                    label: { idleTimeoutText($0) }
                )
            }
            if state.showsDisplayAwake {
                ToggleRow(
                    title: words.keepDisplayAwake,
                    detail: words.keepDisplayAwakeDetail,
                    isOn: Binding(get: { state.keepAwake.keepDisplayAwake }, set: model.setKeepDisplayAwake)
                )
            }
            SettingsFootnote(text: words.lidStillSleepsTheMac)
        }
    }
}

struct DiagnosticsSection: View {
    @EnvironmentObject var model: AppModel
    let state: SettingsPageState
    let push: (Page) -> Void
    private let words = L10n.app

    var body: some View {
        SettingsSection(title: words.diagnostics) {
            ActionRow(title: words.diagnosticsEllipsis, detail: words.diagnosticsDetail, systemImage: "chevron.right") {
                push(.diagnostics)
            }
            ToggleRow(
                title: words.shareCrashReports,
                detail: words.shareCrashReportsDetail,
                isOn: Binding(get: { state.crashReportsShared }, set: model.setCrashReportsShared)
            )
            if state.showsUploadImpossible {
                SettingsFootnote(text: words.crashUploadImpossible)
            }
            if state.showsCrashReport {
                ActionRow(title: words.crashReport, detail: words.crashLogLeft, systemImage: "exclamationmark.triangle") {
                    push(.crashReport)
                }
            }
        }
    }
}

struct UpdatesSection: View {
    @EnvironmentObject var model: AppModel
    let state: SettingsPageState
    private let words = L10n.app

    var body: some View {
        SettingsSection(title: words.updatesSection) {
            UpdateStatusRow(state: state.update, check: model.checkForUpdatesNow, skip: model.skipAvailableUpdate)
            ToggleRow(
                title: words.checkForUpdatesAutomatically,
                detail: words.checkForUpdatesDetail,
                isOn: Binding(get: { state.updateChecksEnabled }, set: model.setUpdateChecksEnabled)
            )
            SettingsFootnote(text: words.updatePrivacyFootnote)
        }
    }
}

struct AboutSection: View {
    let state: SettingsPageState
    let push: (Page) -> Void
    let select: (Destination) -> Void
    private let words = L10n.app

    var body: some View {
        SettingsSection(title: words.aboutSection) {
            LinkRow(title: words.helpAndFaq, detail: words.helpDetail, destination: DishLinks.help)
            ActionRow(title: words.supportDish, detail: words.supportDetail, systemImage: "chevron.right") {
                select(.support)
            }
            LinkRow(title: words.privacyPolicy, detail: "", destination: DishLinks.privacy)
            ActionRow(title: words.openSourceLicenses, detail: words.licensesSubtitle, systemImage: "chevron.right") {
                push(.licenses)
            }
            Text(state.aboutLine)
                .font(DishFont.caption)
                .foregroundColor(DishTheme.muted)
        }
    }
}

/// The places Settings, Support Dish and the Connections pages link to.
enum DishLinks {
    static let help = "https://dish.tinkernorth.com"
    static let privacy = "https://github.com/TinkerNorth/dish-mac/blob/main/PRIVACY.md"
    static let sponsors = "https://github.com/sponsors/TinkerNorth"
    static let koFi = "https://ko-fi.com/tinkernorth"
    static let buyMeACoffee = "https://buymeacoffee.com/tinkernorth"
    /// The free Satellite host app, as the desktops' wizard and Connections page offer it.
    static let satellite = "https://dish.tinkernorth.com/downloads/satellite"
    /// A Moonlight host for a user without one.
    static let sunshine = "https://github.com/LizardByte/Sunshine"
}
