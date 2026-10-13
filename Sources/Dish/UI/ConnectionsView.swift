// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishEngine
import SwiftUI

/// The connection-management sheet: scan, pair, connect, and forget a
/// remembered server. A manual address is the escape hatch when both
/// discovery paths are dead.
struct ConnectionsView: View {

    @EnvironmentObject var model: AppModel
    @EnvironmentObject var wifi: WifiConnectionManager
    @Environment(\.dismiss) private var dismiss
    @State private var manualAddress = ""
    @State private var manualAddressError: String?

    private let words = L10n.app

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().background(DishTheme.outline)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    sectionHeader
                    let rows = connectionRows(known: model.connections, discovered: wifi.discoveredServers)
                    if rows.isEmpty {
                        Text(words.pressScanHint)
                            .font(DishFont.detail)
                            .foregroundColor(DishTheme.muted)
                            .padding(.vertical, 6)
                    } else {
                        ForEach(rows, id: \.key) { row in
                            rowView(row)
                        }
                    }
                    addByAddressRow
                }
                .padding(20)
            }
            if let failure = model.lastFailure {
                ErrorBanner(message: failureText(failure)) { model.clearFailure() }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
            }
            if let manualAddressError {
                ErrorBanner(message: manualAddressError) { self.manualAddressError = nil }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
            }
        }
        .frame(minWidth: 480, minHeight: 540)
        .background(DishTheme.background)
        // SwiftUI cannot activate a second sibling sheet on MainView while
        // this one is up, so pairing is also presented from here.
        .sheet(item: $model.pairingTarget) { server in
            PairingSheet(server: server)
                .environmentObject(model)
                .environmentObject(wifi)
        }
    }

    private var sectionHeader: some View {
        HStack(spacing: 8) {
            BrandIcon(kind: .satellite, state: .default, size: 18)
            SectionHeader(title: words.wifiServersSection)
            if wifi.isScanning {
                DishSpinner(size: 11)
            }
            Spacer()
        }
    }

    private var addByAddressRow: some View {
        HStack(spacing: 8) {
            TextField(words.addByAddressPlaceholder, text: $manualAddress)
                .textFieldStyle(.roundedBorder)
                .font(DishFont.detail)
                .onSubmit { submitManualAddress() }
            Button(words.add) { submitManualAddress() }
                .buttonStyle(DishOutlinedButtonStyle())
                .disabled(manualAddress.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.top, 4)
    }

    private func submitManualAddress() {
        if model.connectManual(manualAddress) {
            manualAddress = ""
        } else {
            manualAddressError = words.invalidAddress
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text(words.connections)
                .font(DishFont.windowTitle)
                .foregroundColor(DishTheme.onSurface)
            Spacer()
            Button {
                model.startScan()
            } label: {
                workingLabel(words.scan, working: words.scanning, isWorking: wifi.isScanning)
            }
            .buttonStyle(DishOutlinedButtonStyle())
            .disabled(wifi.isScanning)
            Button(words.done) { dismiss() }
                .buttonStyle(DishOutlinedButtonStyle())
        }
        .padding(20)
    }

    /// A button label that carries its own spinner while its action runs, so
    /// "disabled" and "working" read as one state.
    @ViewBuilder
    private func workingLabel(_ resting: String, working: String, isWorking: Bool) -> some View {
        if isWorking {
            HStack(spacing: 6) {
                DishSpinner(size: 12)
                Text(working)
            }
        } else {
            Text(resting)
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func rowView(_ row: ConnectionRow) -> some View {
        switch row {
        case let .known(summary): knownRow(summary)
        case let .discovered(server): discoveredRow(server)
        }
    }

    private func knownRow(_ summary: ConnectionSummary) -> some View {
        HStack(spacing: 10) {
            ZStack(alignment: .bottomTrailing) {
                BrandIcon.satellite(for: summary.live, size: 28)
                StatusDot(color: linkDotColor(summary.live))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(summary.label)
                    .font(DishFont.body)
                    .foregroundColor(DishTheme.onSurface)
                Text(summary.detail)
                    .font(DishFont.caption)
                    .foregroundColor(DishTheme.muted)
                Text(statusLine(for: summary))
                    .font(DishFont.monoChip)
                    .foregroundColor(DishTheme.muted)
                if let compat = protocolCompatText(summary.compat) {
                    Text(compat)
                        .font(DishFont.monoChip)
                        .foregroundColor(protocolCompatColor(summary.compat))
                }
                Text(linkTierText(summary.kind))
                    .font(DishFont.monoChip)
                    .foregroundColor(linkTierColor(summary.kind))
                    .help(linkTierHelp(summary.kind))
            }
            Spacer()
            primaryButton(for: summary)
            Button(words.forget) { model.forget(summary.id) }
                .buttonStyle(DishOutlinedButtonStyle())
        }
        .rowBackground()
    }

    private func discoveredRow(_ server: DiscoveredServer) -> some View {
        let pairing = wifi.pairingInFlight.contains(server.id)
        return HStack(spacing: 10) {
            ZStack(alignment: .bottomTrailing) {
                BrandIcon(kind: .satellite, state: .default, size: 28)
                StatusDot(color: DishTheme.muted)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(serverTitle(server))
                    .font(DishFont.body)
                    .foregroundColor(DishTheme.onSurface)
                Text(serverDetail(server))
                    .font(DishFont.caption)
                    .foregroundColor(DishTheme.muted)
                Text(discoveredStatusText(server))
                    .font(DishFont.monoChip)
                    .foregroundColor(DishTheme.muted)
            }
            Spacer()
            Button {
                model.connect(server)
            } label: {
                workingLabel(words.connect, working: words.pairing, isWorking: pairing)
            }
            .buttonStyle(DishOutlinedButtonStyle())
            .disabled(pairing)
        }
        .rowBackground()
    }

    /// The row's main action. Pairing in flight and the session opening both
    /// show as a spinner beside the label with the button disabled, so a
    /// fresh Connect reads as one continuous working state.
    @ViewBuilder
    private func primaryButton(for summary: ConnectionSummary) -> some View {
        let pairing = wifi.pairingInFlight.contains(summary.id)
        switch summary.live {
        case .connected, .unstable:
            Button(words.disconnect) { model.disconnect(summary.id) }
                .buttonStyle(DishOutlinedButtonStyle())
        case .connecting:
            Button(action: ignoreTap) {
                workingLabel(words.connect, working: words.connecting, isWorking: true)
            }
            .buttonStyle(DishOutlinedButtonStyle())
            .disabled(true)
        case .found, .stale, .saved, .ready:
            Button {
                connectRemembered(summary.id)
            } label: {
                workingLabel(words.connect, working: words.pairing, isWorking: pairing)
            }
            .buttonStyle(DishOutlinedButtonStyle())
            .disabled(pairing)
        }
    }

    private func connectRemembered(_ id: String) {
        if let remembered = wifi.remembered().first(where: { $0.id == id }) {
            model.connect(remembered.toDiscovered())
        }
    }

    private func ignoreTap() {}
}

private extension View {
    func rowBackground() -> some View {
        self
            .padding(12)
            .background(DishTheme.surface)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(DishTheme.cardStroke, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
