// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishEngine
import SwiftUI

/// The PIN a Moonlight host asks for, the other way round from a satellite's:
/// the dish minted it, the user types it into the host's own page, and the
/// sheet waits on that. It closes when the host paired or refused; Cancel
/// ends the pairing with nothing written, and New code mints another.
struct MoonlightPinSheet: View {

    @EnvironmentObject var model: AppModel
    let prompt: MoonlightPinPrompt

    private let words = L10n.app

    private var hostName: String {
        moonlightHostTitle(prompt.host)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(words.pairWith(hostName))
                .font(DishFont.sheetTitle)
                .foregroundColor(DishTheme.onSurface)
            Text(prompt.pin)
                .font(DishFont.windowTitle)
                .foregroundColor(DishTheme.primary)
                .textSelection(.enabled)
            Text(words.typePinInto(prompt.pin, hostName))
                .font(DishFont.detail)
                .foregroundColor(DishTheme.muted)
            HStack(spacing: 6) {
                DishSpinner(size: 12)
                Text(words.waitingForTheHostToAcceptThePin)
                    .font(DishFont.caption)
                    .foregroundColor(DishTheme.muted)
            }
            HStack {
                Spacer()
                Button(words.cancel) { model.cancelMoonlightPairing(prompt.host.id) }
                    .buttonStyle(DishOutlinedButtonStyle())
                Button(words.newCode) { mintAnother() }
                    .buttonStyle(DishOutlinedButtonStyle())
            }
        }
        .padding(20)
        .frame(minWidth: 340)
        .background(DishTheme.background)
    }

    private func mintAnother() {
        model.cancelMoonlightPairing(prompt.host.id)
        model.pairMoonlight(prompt.host.id)
    }
}
