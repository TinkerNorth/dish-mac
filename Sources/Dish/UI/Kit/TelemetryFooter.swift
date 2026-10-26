// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import SwiftUI

/// The live figures pinned under Home and Controllers: the rates on the
/// left, the total on the right, in the instrument face.
struct TelemetryFooter: View {
    let rates: String
    let total: String

    var body: some View {
        HStack(spacing: DishSpace.s4) {
            Text(rates)
            Spacer(minLength: DishSpace.s4)
            Text(total)
        }
        .font(DishFont.mono)
        .foregroundColor(DishTheme.muted)
        .padding(.horizontal, DishSpace.page)
        .padding(.vertical, DishSpace.s4)
    }
}
