// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import SwiftUI

/// How a capability pill reads: its ink, whether it is on (filled), and
/// whether the hardware lacks it (outlined dashed and dimmed), so "not
/// available" never reads as "off".
struct CapabilityChipLook: Equatable {
    let ink: Color
    let on: Bool
    let absent: Bool
}

/// One capability pill; the tooltip spells its state out as a second channel.
struct CapabilityChip: View {
    let text: String
    let look: CapabilityChipLook
    var help = ""

    private static let absentOpacity = 0.7

    var body: some View {
        Text(text)
            .font(DishFont.micro)
            .foregroundColor(look.ink)
            .opacity(look.absent ? Self.absentOpacity : 1)
            .padding(.vertical, DishSpace.s1)
            .padding(.horizontal, DishSpace.s3)
            .background(RoundedRectangle(cornerRadius: DishSize.chipRadius).fill(look.on ? DishTheme.chipFill : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: DishSize.chipRadius).stroke(outline, style: outlineStyle))
            .help(help)
    }

    private var outline: Color {
        look.on ? Color.clear : DishTheme.outline
    }

    private var outlineStyle: StrokeStyle {
        StrokeStyle(lineWidth: DishSize.hairline, dash: look.absent ? [DishSize.chipDash] : [])
    }
}
