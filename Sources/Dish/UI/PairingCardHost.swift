// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishEngine
import SwiftUI

/// The pairing card under one satellite's row: it holds the digits being
/// typed, maps the attempt into the card's state, and forwards the card's
/// buttons as intents.
struct PairingCardHost: View {

    @EnvironmentObject var model: AppModel
    let server: DiscoveredServer
    let attempt: PairingAttempt

    @State private var typed = ""

    var body: some View {
        PairingCard(
            state: pairingCardState(attempt, satelliteName: serverTitle(server), typed: typed),
            pin: $typed,
            pair: submit,
            cancel: cancel,
            newCode: newCode
        )
        .onChange(of: typed, perform: clip)
    }

    /// Typing and pasting land in one field; only the digits stay, four at most.
    private func clip(_ raw: String) {
        let clipped = clippedPin(raw)
        if clipped != raw { typed = clipped }
    }

    private func submit() {
        guard isValidPin(typed) else { return }
        model.submitPin(server.id, pin: typed)
    }

    private func cancel() {
        model.cancelPairing(server.id)
    }

    private func newCode() {
        model.newCode(server.id)
    }
}
