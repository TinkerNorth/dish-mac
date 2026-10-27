// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import SwiftUI

/// The inspector's "Input path" section: the pad's player number over the
/// card's path block, so "Not responding?" can be asked from here too.
struct InspectorPathSection: View {
    let state: PadPathState
    let actions: PadPathSection.Actions

    var body: some View {
        VStack(alignment: .leading, spacing: DishSpace.s4) {
            HStack(spacing: DishSpace.s4) {
                SectionHeader(title: state.title)
                if let player = state.player {
                    Text(player)
                        .font(DishFont.monoChip)
                        .foregroundColor(DishTheme.muted)
                }
            }
            InspectorCard {
                PadPathSection(state: state, actions: actions)
            }
        }
    }
}
