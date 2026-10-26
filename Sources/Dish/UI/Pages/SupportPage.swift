// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import SwiftUI

/// Support Dish: the call to action, then each way to give with what it
/// charges and what it takes.
struct SupportPage: View {

    @Environment(\.openURL) private var openURL

    private let state = supportPageState()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DishSpace.s8) {
                hero
                ForEach(state.options) { option in
                    optionRow(option)
                }
            }
            .padding(DishSpace.page)
        }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: DishSpace.s4) {
            Text(state.eyebrow)
                .textCase(.uppercase)
                .font(DishFont.mono)
                .tracking(1.3)
                .foregroundColor(DishTheme.pulse)
            Text(state.headline)
                .font(DishFont.title)
                .foregroundColor(DishTheme.onSurface)
            Button {
                open(state.callToActionURL)
            } label: {
                Label(state.callToAction, systemImage: "heart.fill")
                    .font(DishFont.control)
                    .foregroundColor(DishTheme.onPrimary)
                    .padding(.vertical, DishSpace.s4)
                    .padding(.horizontal, DishSpace.s8)
                    .background(RoundedRectangle(cornerRadius: DishSize.chipRadius).fill(DishTheme.pulse))
            }
            .buttonStyle(.plain)
            Text(state.callToActionNote)
                .font(DishFont.caption)
                .foregroundColor(DishTheme.muted)
            Text(state.thanks)
                .font(DishFont.caption)
                .foregroundColor(DishTheme.muted)
        }
    }

    private func optionRow(_ option: DonationOption) -> some View {
        Button {
            open(option.url)
        } label: {
            VStack(alignment: .leading, spacing: DishSpace.s4) {
                HStack(alignment: .top) {
                    RowText(title: option.name, detail: option.blurb)
                    Spacer()
                    Image(systemName: "arrow.up.right.square")
                        .font(DishFont.icon)
                        .foregroundColor(DishTheme.primary)
                }
                HStack(spacing: DishSpace.s8) {
                    if option.recommended {
                        eyebrow(state.recommendedLabel, colour: DishTheme.pulse)
                    }
                    fact(state.cadenceLabel, option.cadence)
                    fact(state.paysWithLabel, option.paysWith)
                }
            }
            .settingsCard()
        }
        .buttonStyle(.plain)
    }

    private func fact(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: DishSpace.s1) {
            eyebrow(label, colour: DishTheme.muted)
            Text(value)
                .font(DishFont.caption)
                .foregroundColor(DishTheme.onSurface)
        }
    }

    private func eyebrow(_ text: String, colour: Color) -> some View {
        Text(text)
            .textCase(.uppercase)
            .font(DishFont.monoChip)
            .tracking(1)
            .foregroundColor(colour)
    }

    private func open(_ url: URL?) {
        if let url { openURL(url) }
    }
}
