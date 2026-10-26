// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishEngine
import Foundation

/// A list of controllers, or the words for none.
enum SlotListState: Equatable {
    case empty(title: String, body: String)
    case slots([ControllerSlot])
}

struct HomePageState: Equatable {
    let section: String
    /// A satellite is still registering a controller.
    let registering: Bool
    let list: SlotListState
}

func homePageState(slots: [ControllerSlot], registering: Bool, words: L10n = .app) -> HomePageState {
    HomePageState(
        section: words.controllersSection,
        registering: registering,
        list: slots.isEmpty ? .empty(title: words.nothingSetUpYet, body: words.plugOneIn) : .slots(slots)
    )
}
