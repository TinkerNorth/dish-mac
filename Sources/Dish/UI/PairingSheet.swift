// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import SwiftUI

/// PIN-entry sheet shown when the server requires (re-)pairing. Mirrors
/// `dialog_pairing.xml` on Android, which gates the Pair button on a
/// 4-digit numeric PIN.
struct PairingSheet: View {

    @EnvironmentObject var model: AppModel
    @EnvironmentObject var wifi: WifiConnectionManager
    @Environment(\.dismiss) private var dismiss
    let server: DiscoveredServer

    @State private var pin = ""
    @State private var didSubmit = false

    private var serverId: String {
        WifiConnection.idFor(server)
    }

    private var isPairing: Bool {
        wifi.pairingInFlight.contains(serverId)
    }

    private var pinValid: Bool {
        pin.count == 4 && pin.allSatisfy(\.isNumber)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Pair with \(server.name.isEmpty ? server.ip : server.name)")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(DishTheme.onSurface)
            Text("Enter the 4-digit PIN shown on the Satellite server.")
                .font(.system(size: 12))
                .foregroundColor(DishTheme.muted)

            // Inline loader removed: the in-flight state now lives inside the
            // Pair button below (spinner + "Pairing…"), per the design spec.
            // Two loaders for the same submission read as visual noise in a
            // sheet this small.
            TextField("PIN", text: $pin)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 14, design: .monospaced))
                .disabled(isPairing)
                .onChange(of: pin) { newValue in
                    let digits = newValue.filter(\.isNumber)
                    let clipped = String(digits.prefix(4))
                    if clipped != newValue { pin = clipped }
                }

            if didSubmit, let msg = model.errorMessage {
                ErrorBanner(message: msg) {
                    model.errorMessage = nil
                    didSubmit = false
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(DishOutlinedButtonStyle())
                    .disabled(isPairing)
                Button {
                    didSubmit = true
                    model.errorMessage = nil
                    model.pairWithPin(server, pin: pin)
                } label: {
                    if isPairing {
                        HStack(spacing: 6) {
                            DishSpinner(size: 12)
                            Text("Pairing…")
                        }
                    } else {
                        Text("Pair")
                    }
                }
                .buttonStyle(DishOutlinedButtonStyle())
                .disabled(!pinValid || isPairing)
            }
        }
        .padding(20)
        .frame(minWidth: 340)
        .background(DishTheme.background)
        // Once pairing succeeds (connection enters .connecting → .connected) the
        // server is removed from `pairingInFlight`. If no error was raised in
        // the meantime, dismiss the sheet so the user lands back on the
        // connections list with a now-live row.
        .onChange(of: isPairing) { nowPairing in
            if didSubmit, !nowPairing, model.errorMessage == nil {
                dismiss()
            }
        }
    }
}
