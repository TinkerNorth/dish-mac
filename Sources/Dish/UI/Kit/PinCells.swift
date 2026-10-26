// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import SwiftUI

/// A PIN as discrete cells, one digit each, rather than a letter-spaced run
/// of text a screen reader announces badly.
struct PinCells: View {
    let digits: [String]
    let stroke: Color
    let ink: Color

    static let cellWidth: CGFloat = 36
    static let cellHeight: CGFloat = 44
    static let spacing: CGFloat = 8
    private static let cornerRadius: CGFloat = 6

    /// The width of `count` cells side by side.
    static func width(of count: Int) -> CGFloat {
        let cells = CGFloat(count) * cellWidth
        let gaps = CGFloat(max(count - 1, 0)) * spacing
        return cells + gaps
    }

    var body: some View {
        HStack(spacing: Self.spacing) {
            ForEach(digits.indices, id: \.self) { index in
                Text(digits[index])
                    .font(DishFont.pinDigit)
                    .foregroundColor(ink)
                    .frame(width: Self.cellWidth, height: Self.cellHeight)
                    .background(DishTheme.surface)
                    .overlay(RoundedRectangle(cornerRadius: Self.cornerRadius).stroke(stroke, lineWidth: DishSize.hairline))
                    .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius))
            }
        }
        .accessibilityElement(children: .combine)
    }
}
