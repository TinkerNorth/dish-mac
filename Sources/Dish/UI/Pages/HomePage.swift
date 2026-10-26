// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishEngine
import SwiftUI

/// Home: the signal-path wiring diagram. One boxed row per pad, pad node to
/// wire to host node with the binding printed underneath, a ghost "Bind…"
/// card that opens the setup walk on the pad with nowhere to go, the
/// invitation to set one up, and the live figures pinned under it all.
struct HomePage: View {

    @EnvironmentObject var model: AppModel
    @EnvironmentObject var navigation: NavigationStore

    private var state: HomePageState {
        homePageState(HomeInputs(
            slots: model.slots,
            facts: model.shellFacts,
            registering: model.shellFacts.controllerRegistering,
            micPermitted: model.micPermitted
        ))
    }

    var body: some View {
        let state = state
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: DishSpace.s8) {
                    if state.registering {
                        DishSpinner(size: DishSize.buttonSpinner)
                    }
                    content(state.content)
                    if let setUp = state.setUp {
                        SetUpRow(state: setUp, open: openSetup)
                    }
                }
                .padding(DishSpace.page)
            }
            TelemetryFooter(rates: state.footer.rates, total: state.footer.total)
        }
        .onAppear { model.pageAppeared(.home) }
        .onDisappear { model.pageDisappeared(.home) }
    }

    @ViewBuilder
    private func content(_ content: HomeContent) -> some View {
        switch content {
        case let .empty(title, body, action):
            EmptyStateCard(title: title, message: body) {
                Button(action, action: openSetup)
                    .buttonStyle(DishOutlinedButtonStyle())
            }
        case let .rows(rows):
            ForEach(rows) { row in
                SignalRow(state: row, perform: perform, edit: configure, bind: bind)
            }
        }
    }

    private func configure(_ slotId: String) {
        navigation.send(.push(.configureBinding(slotId: slotId)))
    }

    /// A ghost card's Bind…: the walk, its first page answered with this pad.
    private func bind(_ slotId: String) {
        navigation.send(.openSetup(seedSlotId: slotId))
    }

    private func openSetup() {
        navigation.send(.openSetup(seedSlotId: nil))
    }

    /// A strip chip's click: one of the controller's switches, or its mic's mute.
    private func perform(_ action: SlotChipAction, slotId: String) {
        switch action {
        case let .setSwitch(feature, on): model.setSlotSwitch(feature, on: on, slotId: slotId)
        case let .setMicMuted(muted): model.setMicMuted(muted, slotId: slotId)
        }
    }
}
