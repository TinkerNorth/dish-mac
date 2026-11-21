// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import SwiftUI

/// One card: a headline with its dot and chip, then one fact per line with
/// the key in a fixed left column so every card lines up.
struct DiagnosticsCard: View {

    let state: DiagnosticsCardState
    let inspectLabel: String
    let inspect: (String) -> Void

    private static let keyColumn: CGFloat = 150

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if let dot = state.dot {
                    StatusDot(color: dot)
                }
                Text(state.title)
                    .font(DishFont.body)
                    .foregroundColor(DishTheme.onSurface)
                Spacer()
                if let chip = state.chip {
                    Text(chip)
                        .font(DishFont.monoChip)
                        .foregroundColor(DishTheme.muted)
                }
                if let slotId = state.inspects {
                    Button(inspectLabel) { inspect(slotId) }
                        .buttonStyle(DishOutlinedButtonStyle())
                }
            }
            ForEach(state.lines) { line in
                factLine(line)
            }
        }
        .padding(12)
        .background(DishTheme.surface)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(DishTheme.cardStroke, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func factLine(_ line: FactLine) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(line.key)
                .font(DishFont.caption)
                .foregroundColor(DishTheme.muted)
                .frame(width: Self.keyColumn, alignment: .leading)
            Text(line.value)
                .font(DishFont.mono)
                .foregroundColor(DishTheme.onSurface)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}
