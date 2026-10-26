// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import SwiftUI

/// The rail's one action, the desktops' Set up: an outlined accent button
/// between the destinations and the footer, never a destination itself.
/// Collapsed, it is the bare plus and its label becomes the tooltip.
struct RailAction: View {
    let label: String
    let collapsed: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: DishSpace.s5) {
                Image(systemName: "plus")
                    .font(DishFont.icon)
                    .foregroundColor(DishTheme.primary)
                    .frame(width: DishSize.railGlyph, height: DishSize.railGlyph)
                if !collapsed {
                    Text(label)
                        .font(DishFont.railLabelActive)
                        .foregroundColor(DishTheme.primary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, DishSpace.s5)
            .frame(maxWidth: .infinity, minHeight: DishSize.railItemHeight, alignment: collapsed ? .center : .leading)
            .background(
                RoundedRectangle(cornerRadius: DishSize.chipRadius)
                    .fill(DishTheme.railActiveFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DishSize.chipRadius)
                    .stroke(DishTheme.primary, lineWidth: DishSize.hairline)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(collapsed ? label : "")
        .accessibilityLabel(label)
    }
}
