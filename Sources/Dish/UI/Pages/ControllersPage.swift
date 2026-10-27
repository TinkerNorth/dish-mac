// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import DishEngine
import SwiftUI

/// Controllers: the inventory of pads, one card each, with everything that
/// belongs to the device (its input path and its check among it) and the
/// "Bound · host ›" hand-off into Configure binding; the live figures
/// pinned under them.
struct ControllersPage: View {

    @EnvironmentObject var model: AppModel
    @EnvironmentObject var navigation: NavigationStore

    private var state: ControllersPageState {
        controllersPageState(slots: model.slots, facts: model.shellFacts, registering: model.shellFacts.controllerRegistering)
    }

    var body: some View {
        let state = state
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: DishSpace.s5) {
                    if state.registering {
                        DishSpinner(size: DishSize.buttonSpinner)
                    }
                    content(state.content)
                }
                .padding(DishSpace.page)
            }
            TelemetryFooter(rates: state.footer.rates, total: state.footer.total)
        }
        .onAppear { model.pageAppeared(.controllers) }
        .onDisappear { model.pageDisappeared(.controllers) }
    }

    @ViewBuilder
    private func content(_ content: ControllersContent) -> some View {
        switch content {
        case let .empty(title, body):
            EmptyStateCard(title: title, message: body)
        case let .cards(cards):
            ForEach(cards) { card in
                ControllerCard(state: card, actions: actions)
            }
        }
    }

    private var actions: ControllerCard.Actions {
        ControllerCard.Actions(
            configure: configure,
            deadZones: deadZones,
            setMicMuted: model.setMicMuted,
            checkInput: model.startInputCheck,
            pickPath: pickPath,
            helpSupport: helpSupport,
            checkButtons: checkButtons
        )
    }

    private func pickPath(_ source: InputSource, _ slotId: String) {
        model.pickInputPath(slotId: slotId, source)
    }

    private func helpSupport(_ slotId: String) {
        navigation.send(.push(helpSupportPage(forSlot: slotId, slots: model.slots, paths: model.shellFacts.inputPaths)))
    }

    private func checkButtons(_ slotId: String) {
        navigation.send(.push(.checkButtons(slotId: slotId)))
    }

    private func configure(_ slotId: String) {
        navigation.send(.push(.configureBinding(slotId: slotId)))
    }

    private func deadZones(_ slotId: String) {
        navigation.send(.push(.deadZones(slotId: slotId)))
    }
}
