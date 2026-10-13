// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import DishEngine
import SwiftUI

/// The preferences sheet: appearance, the window's behaviour, the forwarded
/// features, power, updates and the about lines. Each switch is a global
/// preference: Dish forwards input, it does not remap it.
struct SettingsView: View {

    @EnvironmentObject var settings: FeatureSettings
    @EnvironmentObject var theme: ThemePreferenceStore
    @EnvironmentObject var background: BackgroundPreferenceStore
    @EnvironmentObject var keepAwake: KeepAwakePreferenceStore
    @EnvironmentObject var updatePreferences: UpdatePreferenceStore
    @EnvironmentObject var updates: UpdateChecker
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var crashLogPresent = false
    @State private var showCrashReport = false
    @Environment(\.dismiss) private var dismiss

    private let words = L10n.app

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider().background(DishTheme.outline)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    appearance
                    window
                    forwardedFeatures
                    power
                    updatesSection
                    about
                }
                .padding(.bottom, 8)
            }
        }
        .padding(20)
        .frame(width: 460, height: 640)
        .background(DishTheme.background)
    }

    private var header: some View {
        HStack {
            Text(words.settings)
                .font(DishFont.title)
                .foregroundColor(DishTheme.onSurface)
            Spacer()
            Button(words.done) { dismiss() }
                .buttonStyle(DishOutlinedButtonStyle())
        }
    }

    // MARK: - Appearance

    private var appearance: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: words.appearanceSection)
            PickerRow(title: words.theme, detail: words.themeDetail) {
                Picker("", selection: Binding(get: { theme.state }, set: theme.setMode)) {
                    ForEach(ThemeMode.allCases, id: \.self) { mode in
                        Text(themeModeText(mode)).tag(mode)
                    }
                }
            }
        }
    }

    // MARK: - Window

    private var window: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: words.windowSection)
            ToggleRow(
                title: words.keepRunningInBackground,
                detail: words.keepRunningDetail,
                isOn: Binding(get: { background.state.runInBackground }, set: background.setRunInBackground)
            )
        }
    }

    // MARK: - Forwarded features

    private var forwardedFeatures: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: words.forwardedFeaturesSection)
            ToggleRow(title: words.motionGyro, detail: words.motionDetail, isOn: $settings.motionEnabled)
            ToggleRow(title: words.rumble, detail: words.rumbleDetail, isOn: $settings.rumbleEnabled)
            ToggleRow(title: words.touchpad, detail: words.touchpadDetail, isOn: $settings.touchpadEnabled)
            PickerRow(title: words.lightBar, detail: words.lightbarDetail) {
                Picker("", selection: $settings.lightbarMode) {
                    ForEach(LightbarMode.allCases) { mode in
                        Text(lightbarModeText(mode)).tag(mode)
                    }
                }
            }
            Text(words.featuresFootnote)
                .font(DishFont.caption)
                .foregroundColor(DishTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Power

    private var power: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: words.powerSection)
            PickerRow(title: words.keepComputerAwake, detail: words.keepAwakeDetail) {
                Picker("", selection: Binding(get: { keepAwake.state.mode }, set: keepAwake.setMode)) {
                    ForEach(KeepAwakeMode.allCases, id: \.self) { mode in
                        Text(keepAwakeModeText(mode)).tag(mode)
                    }
                }
            }
            if keepAwake.state.mode == .whileControllerActive {
                StepperRow(
                    title: words.letGoAfterStillness,
                    value: Binding(get: { keepAwake.state.idleTimeoutMinutes }, set: keepAwake.setIdleTimeoutMinutes),
                    range: KeepAwakeLimits.minTimeoutMinutes ... KeepAwakeLimits.maxTimeoutMinutes,
                    label: { idleTimeoutText($0) }
                )
            }
            if keepAwake.state.mode != .off {
                ToggleRow(
                    title: words.keepDisplayAwake,
                    detail: words.keepDisplayAwakeDetail,
                    isOn: Binding(get: { keepAwake.state.keepDisplayAwake }, set: keepAwake.setKeepDisplayAwake)
                )
            }
        }
    }

    // MARK: - Updates

    private var updatesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: words.updatesSection)
            UpdateStatusRow()
            ToggleRow(
                title: words.checkForUpdatesAutomatically,
                detail: words.checkForUpdatesDetail,
                isOn: Binding(get: { updatePreferences.state.checksEnabled }, set: updatePreferences.setChecksEnabled)
            )
            Text(words.updatePrivacyFootnote)
                .font(DishFont.caption)
                .foregroundColor(DishTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - About

    private var about: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: words.aboutSection)
            LinkRow(title: words.helpAndFaq, detail: words.helpDetail, destination: DishLinks.help)
            LinkRow(title: words.supportDish, detail: words.supportDetail, destination: DishLinks.support)
            LinkRow(title: words.privacyPolicy, detail: "", destination: DishLinks.privacy)
            LinkRow(title: words.openSourceLicenses, detail: words.licensesDetail, destination: DishLinks.license)
            ActionRow(title: words.diagnostics, detail: words.diagnosticsDetail, systemImage: "waveform.path.ecg") {
                openWindow(id: DishWindow.diagnostics)
            }
            if crashLogPresent {
                ActionRow(title: words.crashReport, detail: words.crashLogLeft, systemImage: "exclamationmark.triangle") {
                    showCrashReport = true
                }
            }
            Text(words.aboutLine(updates.state.currentVersion))
                .font(DishFont.caption)
                .foregroundColor(DishTheme.muted)
        }
        .onAppear { crashLogPresent = model.crashLog.exists }
        .sheet(isPresented: $showCrashReport) {
            CrashReportSheet(report: crashReportText(model.crashLog, appVersion: updates.state.currentVersion)) {
                model.crashLog.discard()
                crashLogPresent = false
            }
        }
    }
}

/// The places the About section links to.
enum DishLinks {
    static let help = "https://dish.tinkernorth.com"
    static let support = "https://github.com/sponsors/TinkerNorth"
    static let privacy = "https://github.com/TinkerNorth/dish-mac/blob/main/PRIVACY.md"
    static let license = "https://github.com/TinkerNorth/dish-mac/blob/main/THIRD_PARTY.md"
}
