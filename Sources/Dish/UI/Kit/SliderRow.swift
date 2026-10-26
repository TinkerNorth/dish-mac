// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import SwiftUI

/// A labelled slider over whole steps with its live readout; every move is
/// handed on as it happens.
struct SliderRow: View {
    let label: String
    let readout: String
    let value: Int
    let maxValue: Int
    let change: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DishSpace.s2) {
            HStack {
                Text(label)
                    .font(DishFont.detail)
                    .foregroundColor(DishTheme.onSurface)
                Spacer()
                Text(readout)
                    .font(DishFont.mono)
                    .foregroundColor(DishTheme.primary)
            }
            Slider(value: position, in: 0 ... Double(maxValue), step: 1)
                .accessibilityLabel(label)
                .accessibilityValue(readout)
        }
    }

    private var position: Binding<Double> {
        Binding(get: { Double(value) }, set: moved)
    }

    private func moved(_ position: Double) {
        change(Int(position.rounded()))
    }
}
