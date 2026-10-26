// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishEngine
import SwiftUI

/// A themed feature toggle: title and explanation on the left, the switch
/// on the right.
struct ToggleRow: View {

    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RowText(title: title, detail: detail)
            Spacer()
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(DishTheme.primary)
        }
        .settingsCard()
    }
}

/// A row with a menu picker on the right.
struct PickerRow<Content: View>: View {

    let title: String
    let detail: String
    @ViewBuilder let picker: () -> Content

    var body: some View {
        HStack(alignment: .top) {
            RowText(title: title, detail: detail)
            Spacer()
            picker()
                .labelsHidden()
                .pickerStyle(.menu)
                .tint(DishTheme.primary)
                .frame(width: 150)
        }
        .settingsCard()
    }
}

/// A row with a stepper over an integer and the label the mapper gives it.
struct StepperRow: View {

    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    let label: (Int) -> String

    var body: some View {
        HStack(alignment: .center) {
            Text(title)
                .font(DishFont.body)
                .foregroundColor(DishTheme.onSurface)
            Spacer()
            Text(label(value))
                .font(DishFont.detail)
                .foregroundColor(DishTheme.muted)
            Stepper("", value: $value, in: range)
                .labelsHidden()
        }
        .settingsCard()
    }
}

/// A row that acts inside the app, its glyph on the right.
struct ActionRow: View {

    let title: String
    let detail: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top) {
                RowText(title: title, detail: detail)
                Spacer()
                Image(systemName: systemImage)
                    .font(DishFont.icon)
                    .foregroundColor(DishTheme.primary)
            }
            .settingsCard()
        }
        .buttonStyle(.plain)
    }
}

/// A row that opens a web page.
struct LinkRow: View {

    @Environment(\.openURL) private var openURL
    let title: String
    let detail: String
    let destination: String

    var body: some View {
        Button(action: open) {
            HStack(alignment: .top) {
                RowText(title: title, detail: detail)
                Spacer()
                Image(systemName: "arrow.up.right.square")
                    .font(DishFont.icon)
                    .foregroundColor(DishTheme.primary)
            }
            .settingsCard()
        }
        .buttonStyle(.plain)
    }

    private func open() {
        if let url = URL(string: destination) { openURL(url) }
    }
}

/// The Updates section's status line and its actions, as the mapper words them.
struct UpdateStatusRow: View {

    let state: UpdateRowState
    let check: () -> Void
    let skip: () -> Void
    @Environment(\.openURL) private var openURL

    private let words = L10n.app

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(state.status)
                .font(DishFont.detail)
                .foregroundColor(state.statusColor)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button(words.checkForUpdates, action: check)
                    .buttonStyle(DishOutlinedButtonStyle())
                    .disabled(!state.canCheck)
                if let releasePage = state.releasePage {
                    Button(words.openReleasePage) { openURL(releasePage) }
                        .buttonStyle(DishOutlinedButtonStyle())
                }
                if state.offersSkip {
                    Button(words.skipThisVersion, action: skip)
                        .buttonStyle(DishOutlinedButtonStyle())
                }
            }
        }
        .settingsCard()
    }
}

/// A row's title and explanation.
struct RowText: View {

    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(DishFont.body)
                .foregroundColor(DishTheme.onSurface)
            if !detail.isEmpty {
                Text(detail)
                    .font(DishFont.caption)
                    .foregroundColor(DishTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

extension View {
    func settingsCard() -> some View {
        self
            .padding(12)
            .background(DishTheme.surface)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(DishTheme.cardStroke, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
