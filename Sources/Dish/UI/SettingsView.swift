// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import SwiftUI

/// Feature-forwarding preferences sheet. Presented from the gear button in
/// `MainView`. Each row gates one forwarded controller feature; the copy
/// explains what turning it off does, because "rumble off" reads ambiguously
/// otherwise (does my controller still rumble locally? — no, this is about
/// what the *host game* sends back).
///
/// These are global, not per-controller: Dish forwards input, it doesn't remap
/// it, so "should this machine forward gyro" is the meaningful question. The
/// layout mirrors what DS4Windows / Steam Input expose — a flat list of
/// feature switches plus a light-bar mode — minus the remapping surface Dish
/// doesn't have.
struct SettingsView: View {

    @EnvironmentObject var settings: FeatureSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Settings")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(DishTheme.onSurface)
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(DishOutlinedButtonStyle())
            }

            Divider().background(DishTheme.outline)

            SectionHeader(title: "FORWARDED FEATURES")

            VStack(spacing: 8) {
                ToggleRow(
                    title: "Motion (gyro)",
                    detail: "Forward gyroscope and accelerometer to the host — "
                        + "used for motion aiming in games that support it.",
                    isOn: $settings.motionEnabled
                )
                ToggleRow(
                    title: "Rumble",
                    detail: "Play vibration the host game sends back on your "
                        + "controller.",
                    isOn: $settings.rumbleEnabled
                )
                ToggleRow(
                    title: "Touchpad",
                    detail: "Forward the DualSense / DualShock 4 touchpad. "
                        + "Controllers without a touchpad ignore this.",
                    isOn: $settings.touchpadEnabled
                )
                lightbarRow
            }

            Text("Features only apply when your controller's hardware "
                + "supports them — the controller list shows what was detected.")
                .font(.system(size: 11))
                .foregroundColor(DishTheme.muted)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(width: 420, height: 460)
        .background(DishTheme.background)
    }

    // MARK: - Light bar (a mode picker, not a toggle)

    private var lightbarRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Light bar")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(DishTheme.onSurface)
                    Text("Follow game: the controller LED matches the host "
                        + "game. Off: leave the LED untouched.")
                        .font(.system(size: 11))
                        .foregroundColor(DishTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Picker("", selection: $settings.lightbarMode) {
                    ForEach(LightbarMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .tint(DishTheme.primary)
                .frame(width: 130)
            }
        }
        .padding(12)
        .background(DishTheme.surface)
        .overlay(
            RoundedRectangle(cornerRadius: 8).stroke(DishTheme.cardStroke, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

/// A themed feature toggle: title + explanatory detail on the left, a
/// `Toggle` on the right. Matches the `SlotCard` card styling.
private struct ToggleRow: View {

    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(DishTheme.onSurface)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundColor(DishTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(DishTheme.primary)
        }
        .padding(12)
        .background(DishTheme.surface)
        .overlay(
            RoundedRectangle(cornerRadius: 8).stroke(DishTheme.cardStroke, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
