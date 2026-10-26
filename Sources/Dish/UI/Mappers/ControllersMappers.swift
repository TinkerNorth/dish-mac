// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishEngine
import Foundation

struct ControllersPageState: Equatable {
    let registering: Bool
    let list: SlotListState
}

func controllersPageState(slots: [ControllerSlot], registering: Bool, words: L10n = .app) -> ControllersPageState {
    ControllersPageState(
        registering: registering,
        list: slots.isEmpty ? .empty(title: words.noControllersConnected, body: words.plugOneIn) : .slots(slots)
    )
}
