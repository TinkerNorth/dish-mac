// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import SwiftUI

/// A small word on a tinted capsule: a link's tier, its state, its trust.
/// The colour token is the state; the fill is the one chip tint.
struct StateChip: View {
    let text: String
    let color: Color
    var help = ""

    var body: some View {
        Text(text)
            .font(DishFont.monoChip)
            .foregroundColor(color)
            .padding(.horizontal, DishSpace.s3)
            .padding(.vertical, DishSpace.s1)
            .background(RoundedRectangle(cornerRadius: DishSize.chipRadius).fill(DishTheme.chipFill))
            .help(help)
    }
}
