// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import SwiftUI

/// The rail: Home, Controllers and Connections at the top; Support Dish and
/// Settings pinned to the footer over the version label. Collapsed, it is
/// an icon strip whose items name themselves in their tooltips.
struct RailView: View {

    let state: ShellState
    let select: (Destination) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DishSpace.s2) {
            ForEach(state.top) { item in
                railItem(item)
            }
            Spacer(minLength: DishSpace.s8)
            Divider()
                .background(DishTheme.outline)
                .padding(.vertical, DishSpace.s4)
            ForEach(state.footer) { item in
                railItem(item)
            }
            if !state.railCollapsed {
                Text(state.version)
                    .font(DishFont.monoChip)
                    .foregroundColor(DishTheme.muted)
                    .padding(.leading, DishSpace.s5)
                    .padding(.top, DishSpace.s6)
            }
        }
        .padding(.horizontal, DishSpace.s4)
        .padding(.top, DishSpace.s4)
        .padding(.bottom, DishSpace.s8)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func railItem(_ item: RailItemState) -> some View {
        RailItem(label: item.label, active: item.active, collapsed: state.railCollapsed, badge: item.badge) {
            select(item.destination)
        } glyph: {
            RailGlyphView(glyph: item.glyph)
        }
    }
}

/// A rail item's picture: the brand glyphs for the three top destinations,
/// the pulse heart for Support Dish, the gear for Settings.
struct RailGlyphView: View {
    let glyph: RailGlyph

    var body: some View {
        switch glyph {
        case .dish: BrandIcon(kind: .dish, state: .default, size: DishSize.railGlyph)
        case .pad: BrandIcon(kind: .pad, state: .default, size: DishSize.railGlyph)
        case .satellite: BrandIcon(kind: .satellite, state: .default, size: DishSize.railGlyph)
        case .heart: symbol("heart.fill", colour: DishTheme.pulse)
        case .gear: symbol("gearshape.fill", colour: DishTheme.brandGlyph)
        }
    }

    private func symbol(_ name: String, colour: Color) -> some View {
        Image(systemName: name)
            .font(DishFont.icon)
            .foregroundColor(colour)
    }
}
