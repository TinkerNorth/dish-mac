// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishEngine
import SwiftUI

/// The PIN sheet shown when a server requires pairing. The Pair button is
/// gated on a four-digit PIN, the length the satellite rotates.
struct PairingSheet: View {

    @EnvironmentObject var model: AppModel
    @EnvironmentObject var wifi: WifiConnectionManager
    @Environment(\.dismiss) private var dismiss
    let server: DiscoveredServer

    @State private var pin = ""
    @State private var didSubmit = false

    private let words = L10n.app

    private var isPairing: Bool {
        wifi.pairingInFlight.contains(WifiConnection.idFor(server))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(words.pairWith(serverTitle(server)))
                .font(DishFont.sheetTitle)
                .foregroundColor(DishTheme.onSurface)
            Text(words.enterPin)
                .font(DishFont.detail)
                .foregroundColor(DishTheme.muted)

            TextField(words.pin, text: $pin)
                .textFieldStyle(.roundedBorder)
                .font(DishFont.monoField)
                .disabled(isPairing)
                .onChange(of: pin, perform: clipPin)

            if didSubmit, let failure = model.lastFailure {
                ErrorBanner(message: failureText(failure)) {
                    model.clearFailure()
                    didSubmit = false
                }
            }

            HStack {
                Spacer()
                Button(words.cancel) { dismiss() }
                    .buttonStyle(DishOutlinedButtonStyle())
                    .disabled(isPairing)
                Button(action: submit) {
                    if isPairing {
                        HStack(spacing: 6) {
                            DishSpinner(size: 12)
                            Text(words.pairing)
                        }
                    } else {
                        Text(words.pair)
                    }
                }
                .buttonStyle(DishOutlinedButtonStyle())
                .disabled(!isValidPin(pin) || isPairing)
            }
        }
        .padding(20)
        .frame(minWidth: 340)
        .background(DishTheme.background)
        .onChange(of: isPairing, perform: dismissWhenPaired)
    }

    private func clipPin(_ typed: String) {
        let clipped = clippedPin(typed)
        if clipped != typed { pin = clipped }
    }

    private func submit() {
        didSubmit = true
        model.clearFailure()
        model.pairWithPin(server, pin: pin)
    }

    /// Pairing ends with the row live or with a failure; only the first
    /// closes the sheet.
    private func dismissWhenPaired(_ nowPairing: Bool) {
        if didSubmit, !nowPairing, model.lastFailure == nil {
            dismiss()
        }
    }
}
