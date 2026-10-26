// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishEngine
import SwiftUI

/// Controllers: a card per pad with its switches and its binding.
struct ControllersPage: View {

    @EnvironmentObject var model: AppModel
    @EnvironmentObject var wifi: WifiConnectionManager

    private var state: ControllersPageState {
        controllersPageState(slots: model.slots, registering: wifi.anyControllerRegistering)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DishSpace.s5) {
                if state.registering {
                    DishSpinner(size: DishSize.buttonSpinner)
                }
                SlotList(state: state.list)
            }
            .padding(DishSpace.page)
        }
    }
}
