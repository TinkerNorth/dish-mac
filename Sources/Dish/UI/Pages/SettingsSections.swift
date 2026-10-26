// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import DishEngine
import SwiftUI

struct AppearanceSection: View {
    @EnvironmentObject var theme: ThemePreferenceStore
    private let words = L10n.app

    var body: some View {
        SettingsSection(title: words.appearanceSection) {
            PickerRow(title: words.theme, detail: words.themeDetail) {
                Picker("", selection: Binding(get: { theme.state }, set: theme.setMode)) {
                    ForEach(ThemeMode.allCases, id: \.self) { mode in
                        Text(themeModeText(mode)).tag(mode)
                    }
                }
            }
        }
    }
}

struct ForwardedFeaturesSection: View {
    @EnvironmentObject var settings: FeatureSettings
    private let words = L10n.app

    var body: some View {
        SettingsSection(title: words.forwardedFeaturesSection) {
            ToggleRow(title: words.rumble, detail: words.rumbleDetail, isOn: $settings.rumbleEnabled)
            ToggleRow(title: words.touchpad, detail: words.touchpadDetail, isOn: $settings.touchpadEnabled)
            PickerRow(title: words.lightBar, detail: words.lightbarDetail) {
                Picker("", selection: $settings.lightbarMode) {
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
    @EnvironmentObject var settings: FeatureSettings
    private let words = L10n.app

    var body: some View {
        SettingsSection(title: words.controllerTuningSection) {
            ToggleRow(title: words.motionGyro, detail: words.motionDetail, isOn: $settings.motionEnabled)
        }
    }
}

struct WindowSection: View {
    @EnvironmentObject var background: BackgroundPreferenceStore
    private let words = L10n.app

    var body: some View {
        SettingsSection(title: words.windowSection) {
            ToggleRow(
                title: words.keepRunningInBackground,
                detail: words.keepRunningDetail,
                isOn: Binding(get: { background.state.runInBackground }, set: background.setRunInBackground)
            )
        }
    }
}

struct PowerSection: View {
    @EnvironmentObject var keepAwake: KeepAwakePreferenceStore
    let state: SettingsPageState
    private let words = L10n.app

    var body: some View {
        SettingsSection(title: words.powerSection) {
            PickerRow(title: words.keepComputerAwake, detail: words.keepAwakeDetail) {
                Picker("", selection: Binding(get: { keepAwake.state.mode }, set: keepAwake.setMode)) {
                    ForEach(KeepAwakeMode.allCases, id: \.self) { mode in
                        Text(keepAwakeModeText(mode)).tag(mode)
                    }
                }
            }
            if state.showsIdleTimeout {
                StepperRow(
                    title: words.letGoAfterStillness,
                    value: Binding(get: { keepAwake.state.idleTimeoutMinutes }, set: keepAwake.setIdleTimeoutMinutes),
                    range: KeepAwakeLimits.minTimeoutMinutes ... KeepAwakeLimits.maxTimeoutMinutes,
                    label: { idleTimeoutText($0) }
                )
            }
            if state.showsDisplayAwake {
                ToggleRow(
                    title: words.keepDisplayAwake,
                    detail: words.keepDisplayAwakeDetail,
                    isOn: Binding(get: { keepAwake.state.keepDisplayAwake }, set: keepAwake.setKeepDisplayAwake)
                )
            }
            SettingsFootnote(text: words.lidStillSleepsTheMac)
        }
    }
}

struct DiagnosticsSection: View {
    @EnvironmentObject var crashReporting: CrashReportingController
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
                isOn: Binding(get: { crashReporting.state }, set: crashReporting.setEnabled)
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
    @EnvironmentObject var updatePreferences: UpdatePreferenceStore
    private let words = L10n.app

    var body: some View {
        SettingsSection(title: words.updatesSection) {
            UpdateStatusRow()
            ToggleRow(
                title: words.checkForUpdatesAutomatically,
                detail: words.checkForUpdatesDetail,
                isOn: Binding(get: { updatePreferences.state.checksEnabled }, set: updatePreferences.setChecksEnabled)
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

/// The places Settings and Support Dish link to.
enum DishLinks {
    static let help = "https://dish.tinkernorth.com"
    static let privacy = "https://github.com/TinkerNorth/dish-mac/blob/main/PRIVACY.md"
    static let sponsors = "https://github.com/sponsors/TinkerNorth"
    static let koFi = "https://ko-fi.com/tinkernorth"
    static let buyMeACoffee = "https://buymeacoffee.com/tinkernorth"
}
