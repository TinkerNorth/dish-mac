// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import SwiftUI

/// The header over every page: the back chevron while a page is pushed, the
/// title, the streaming pill with its Configure button, the app-wide
/// microphone chip, and the status line. Values in, taps out.
struct ShellHeader: View {

    struct Actions {
        let back: () -> Void
        let configure: () -> Void
        let toggleMic: () -> Void
    }

    let state: ShellState
    let backLabel: String
    let actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: DishSpace.s4) {
            HStack(spacing: DishSpace.s6) {
                if state.showsBack {
                    Button(action: actions.back) {
                        Image(systemName: "chevron.left")
                            .font(DishFont.icon)
                            .foregroundColor(DishTheme.muted)
                    }
                    .buttonStyle(.plain)
                    .help(backLabel)
                    .accessibilityLabel(backLabel)
                }
                Text(state.title)
                    .font(DishFont.pageTitle)
                    .foregroundColor(DishTheme.onSurface)
                    .lineLimit(1)
                if let pill = state.pill {
                    StreamingPill(text: pill.text)
                    Button(pill.configure, action: actions.configure)
                        .buttonStyle(DishOutlinedButtonStyle())
                        .accessibilityLabel(pill.configureHelp)
                }
                if let mic = state.mic {
                    MicChip(state: mic, toggle: actions.toggleMic)
                }
                Spacer(minLength: 0)
            }
            subline
        }
        .padding(.horizontal, DishSpace.page)
        .padding(.top, DishSpace.s8)
        .padding(.bottom, DishSpace.s4)
    }

    @ViewBuilder
    private var subline: some View {
        switch state.subline {
        case let .status(headline, summary, accent):
            HStack(spacing: DishSpace.s4) {
                StatusDot(color: accent)
                Text(headline)
                    .font(DishFont.control)
                    .foregroundColor(accent)
                Text(summary)
                    .font(DishFont.detail)
                    .foregroundColor(DishTheme.muted)
            }
            .lineLimit(1)
        case let .note(text):
            Text(text)
                .font(DishFont.detail)
                .foregroundColor(DishTheme.muted)
                .lineLimit(1)
        }
    }
}

/// The shell's one streaming surface.
struct StreamingPill: View {
    let text: String

    var body: some View {
        Text(text)
            .textCase(.uppercase)
            .font(DishFont.monoChip)
            .tracking(1)
            .foregroundColor(DishTheme.primary)
            .padding(.vertical, DishSpace.s2)
            .padding(.horizontal, DishSpace.s5)
            .background(RoundedRectangle(cornerRadius: DishSize.chipRadius).fill(DishTheme.pillFill))
            .overlay(RoundedRectangle(cornerRadius: DishSize.chipRadius).stroke(DishTheme.outline, lineWidth: DishSize.hairline))
            .accessibilityLabel(text)
    }
}

/// Live wears the error tone: an open microphone is what the app reserves
/// that colour for. Muted stays visible but calm, so the mute can be undone.
struct MicChip: View {
    let state: MicChipState
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            Text(state.text)
                .textCase(.uppercase)
                .font(DishFont.monoChip)
                .tracking(1)
                .foregroundColor(state.live ? DishTheme.error : DishTheme.muted)
                .padding(.vertical, DishSpace.s2)
                .padding(.horizontal, DishSpace.s5)
                .background(RoundedRectangle(cornerRadius: DishSize.chipRadius)
                    .fill(state.live ? DishTheme.errorFill : DishTheme.surfaceDim))
                .overlay(RoundedRectangle(cornerRadius: DishSize.chipRadius).stroke(DishTheme.outline, lineWidth: DishSize.hairline))
        }
        .buttonStyle(.plain)
        .help(state.help)
        .accessibilityLabel(state.help)
    }
}
