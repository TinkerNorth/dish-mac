// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import SwiftUI

/// One rail destination: a fixed glyph cell, so the column holds as the rail
/// collapses, the label beside it, the accent bar and fill while it is the
/// destination on screen, and an optional dot on the glyph. Collapsed, the
/// label becomes the tooltip.
struct RailItem<Glyph: View>: View {

    let label: String
    let active: Bool
    let collapsed: Bool
    let badge: Color?
    let action: () -> Void
    @ViewBuilder let glyph: () -> Glyph

    var body: some View {
        Button(action: action) {
            HStack(spacing: DishSpace.s5) {
                glyphCell
                if !collapsed {
                    Text(label)
                        .font(active ? DishFont.railLabelActive : DishFont.railLabel)
                        .foregroundColor(active ? DishTheme.onSurface : DishTheme.muted)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, DishSpace.s5)
            .frame(maxWidth: .infinity, minHeight: DishSize.railItemHeight, alignment: collapsed ? .center : .leading)
            .background(background)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(collapsed ? label : "")
        .accessibilityLabel(label)
    }

    private var glyphCell: some View {
        glyph()
            .frame(width: DishSize.railGlyph, height: DishSize.railGlyph)
            .overlay(alignment: .topTrailing) {
                if let badge {
                    Circle()
                        .fill(badge)
                        .frame(width: DishSize.badge, height: DishSize.badge)
                        .accessibilityHidden(true)
                }
            }
    }

    private var background: some View {
        RoundedRectangle(cornerRadius: DishSize.chipRadius)
            .fill(active ? DishTheme.railActiveFill : Color.clear)
            .overlay(alignment: .leading) {
                if active {
                    RoundedRectangle(cornerRadius: DishSize.railAccentBar)
                        .fill(DishTheme.primary)
                        .frame(width: DishSize.railAccentBar, height: DishSize.railGlyph)
                }
            }
    }
}
