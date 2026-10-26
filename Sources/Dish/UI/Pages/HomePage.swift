// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishEngine
import SwiftUI

/// Home: every controller and where it goes.
struct HomePage: View {

    @EnvironmentObject var model: AppModel
    @EnvironmentObject var wifi: WifiConnectionManager

    private var state: HomePageState {
        homePageState(slots: model.slots, registering: wifi.anyControllerRegistering)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DishSpace.s5) {
                HStack(spacing: DishSpace.s4) {
                    SectionHeader(title: state.section)
                    if state.registering {
                        DishSpinner(size: DishSize.buttonSpinner)
                    }
                    Spacer()
                }
                SlotList(state: state.list)
            }
            .padding(DishSpace.page)
        }
    }
}
