// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishEngine
import SwiftUI

/// The forwarding preferences: one switch per forwarded controller feature
/// and the light-bar mode. Global, not per controller: Dish forwards input,
/// it does not remap it.
struct SettingsView: View {

    @EnvironmentObject var settings: FeatureSettings
    @Environment(\.dismiss) private var dismiss

    private let words = L10n.app

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(words.settings)
                    .font(DishFont.title)
                    .foregroundColor(DishTheme.onSurface)
                Spacer()
                Button(words.done) { dismiss() }
                    .buttonStyle(DishOutlinedButtonStyle())
            }

            Divider().background(DishTheme.outline)

            SectionHeader(title: words.forwardedFeaturesSection)

            VStack(spacing: 8) {
                ToggleRow(title: words.motionGyro, detail: words.motionDetail, isOn: $settings.motionEnabled)
                ToggleRow(title: words.rumble, detail: words.rumbleDetail, isOn: $settings.rumbleEnabled)
                ToggleRow(title: words.touchpad, detail: words.touchpadDetail, isOn: $settings.touchpadEnabled)
                lightbarRow
            }

            Text(words.featuresFootnote)
                .font(DishFont.caption)
                .foregroundColor(DishTheme.muted)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(width: 420, height: 460)
        .background(DishTheme.background)
    }

    /// A mode picker, not a toggle.
    private var lightbarRow: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(words.lightBar)
                    .font(DishFont.body)
                    .foregroundColor(DishTheme.onSurface)
                Text(words.lightbarDetail)
                    .font(DishFont.caption)
                    .foregroundColor(DishTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Picker("", selection: $settings.lightbarMode) {
                ForEach(LightbarMode.allCases) { mode in
                    Text(lightbarModeText(mode)).tag(mode)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .tint(DishTheme.primary)
            .frame(width: 130)
        }
        .settingsCard()
    }
}

/// A themed feature toggle: title and explanation on the left, the switch
/// on the right.
private struct ToggleRow: View {

    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(DishFont.body)
                    .foregroundColor(DishTheme.onSurface)
                Text(detail)
                    .font(DishFont.caption)
                    .foregroundColor(DishTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(DishTheme.primary)
        }
        .settingsCard()
    }
}

private extension View {
    func settingsCard() -> some View {
        self
            .padding(12)
            .background(DishTheme.surface)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(DishTheme.cardStroke, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
