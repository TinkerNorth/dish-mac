// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import SwiftUI

/// The controllers, one card each, or the empty state; Home and Controllers
/// both draw it.
struct SlotList: View {
    let state: SlotListState

    var body: some View {
        switch state {
        case let .empty(title, body):
            EmptyStateCard(title: title, message: body)
        case let .slots(slots):
            VStack(spacing: DishSpace.s4) {
                ForEach(slots) { slot in
                    SlotCard(slot: slot)
                }
            }
        }
    }
}
