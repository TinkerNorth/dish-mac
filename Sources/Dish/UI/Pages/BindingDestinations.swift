// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import SwiftUI

/// Where the pad goes: the paired satellites, then the Moonlight hosts in
/// their own list, because the two pair differently; or, with nowhere to
/// go, the way to Connections.
struct DestinationSection: View {
    let state: DestinationSectionState
    let pick: (String) -> Void
    let manage: () -> Void

    var body: some View {
        BindingSection(title: state.title) {
            if let empty = state.empty {
                EmptyStateCard(title: empty.title, message: empty.message) {
                    Button(state.manage, action: manage)
                        .buttonStyle(DishOutlinedButtonStyle())
                }
            }
            ForEach(state.satellites) { row in
                DestinationRow(state: row, pick: pick)
            }
            if !state.moonlight.isEmpty {
                Text(state.moonlightTitle)
                    .font(DishFont.caption)
                    .foregroundColor(DishTheme.muted)
                ForEach(state.moonlight) { row in
                    DestinationRow(state: row, pick: pick)
                }
            }
            if state.empty == nil {
                Button(state.manage, action: manage)
                    .buttonStyle(.link)
                    .font(DishFont.caption)
            }
        }
    }
}

private struct DestinationRow: View {
    let state: DestinationRowState
    let pick: (String) -> Void

    var body: some View {
        Button(action: pickThis) {
            HStack(spacing: DishSpace.s4) {
                Image(systemName: state.look.glyph)
                    .font(DishFont.icon)
                    .foregroundColor(state.look.ink)
                StatusDot(color: state.dot)
                VStack(alignment: .leading, spacing: DishSpace.s1) {
                    Text(state.title)
                        .font(DishFont.control)
                        .foregroundColor(DishTheme.onSurface)
                    Text(state.subtitle)
                        .font(DishFont.microRegular)
                        .foregroundColor(DishTheme.muted)
                }
                Spacer()
                StateChip(text: state.chip.text, color: state.chip.color)
            }
            .padding(DishSpace.s4)
            .background(state.look.fill)
            .clipShape(RoundedRectangle(cornerRadius: DishSize.chipRadius))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func pickThis() {
        pick(state.id)
    }
}
