// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import SwiftUI

/// Connection-management sheet. Mirrors `ConnectionsActivity` (WiFi-only):
/// scan → pair → connect, plus forget for remembered entries.
struct ConnectionsView: View {

    @EnvironmentObject var model: AppModel
    @EnvironmentObject var wifi: WifiConnectionManager
    @Environment(\.dismiss) private var dismiss
    @State private var manualAddress = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().background(DishTheme.outline)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 8) {
                        // v6 brand satellite glyph anchors the section so the
                        // SwiftUI WI-FI SERVERS header reads visually the same
                        // as the dish-android ImageView + label and the
                        // satellite/web section-glyph in the dashboard.
                        BrandIcon(kind: .satellite, state: .default, size: 18)
                        SectionHeader(title: String(localized: "WI-FI SERVERS"))
                        if wifi.isScanning {
                            // Mirror of the Scan-button loader: same vocabulary
                            // (DishSpinner) at the section level so the user
                            // can see "this list might still update" without
                            // looking back at the header button.
                            DishSpinner(size: 11)
                        }
                        Spacer()
                    }
                    if combinedRows.isEmpty {
                        Text("Press Scan to look for servers on your LAN")
                            // SwiftUI's `Text(literal:)` initializer treats this
                            // bare string literal as a `LocalizedStringKey`, so
                            // the `.xcstrings` "Press Scan…" entry resolves
                            // automatically without an explicit wrap.
                            .font(.system(size: 12))
                            .foregroundColor(DishTheme.muted)
                            .padding(.vertical, 6)
                    } else {
                        ForEach(combinedRows, id: \.key) { row in
                            rowView(row)
                        }
                    }
                    addByAddressRow
                }
                .padding(20)
            }
            if let msg = model.errorMessage {
                ErrorBanner(message: msg) { model.errorMessage = nil }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
            }
        }
        .frame(minWidth: 480, minHeight: 540)
        .background(DishTheme.background)
        // Pairing is presented from here (in addition to MainView) because
        // SwiftUI cannot activate a second sibling `.sheet` on MainView while
        // this sheet is already presented. Nesting the pairing sheet inside
        // the currently-presented view is the only way to make it appear
        // when the user clicks Connect from this page.
        .sheet(item: $model.pairingTarget) { server in
            PairingSheet(server: server)
                .environmentObject(model)
                .environmentObject(wifi)
        }
    }

    // The escape hatch when both discovery paths are dead (Local Network
    // permission denied, multicast-blocked LAN): a manual address seeds the
    // normal pair/connect flow via the legacy `wifi:<ip>:<port>` identity.
    private var addByAddressRow: some View {
        HStack(spacing: 8) {
            TextField("Add by IP — e.g. 192.168.1.50 or 192.168.1.50:9876", text: $manualAddress)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .onSubmit { submitManualAddress() }
            Button(String(localized: "Add")) { submitManualAddress() }
                .buttonStyle(DishOutlinedButtonStyle())
                .disabled(manualAddress.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.top, 4)
    }

    private func submitManualAddress() {
        if model.connectManual(manualAddress) {
            manualAddress = ""
        } else {
            model.errorMessage = String(localized: "Enter an IPv4 address like 192.168.1.50 (optionally :port)")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            // SwiftUI auto-localizes `Text("…")` against the `LocalizedStringKey`
            // initializer, so "Connections" resolves through the catalog.
            Text("Connections")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(DishTheme.onSurface)
            Spacer()
            // Scan is non-atomic (~4 s discoveryRepo timeout) → loader lives
            // *inside* the button so disabled-state and "working"-state read
            // as one thing per the design spec. Button-style opacity at 0.4
            // (see DishOutlinedButtonStyle) carries the not-tappable signal.
            Button {
                model.startScan()
            } label: {
                if wifi.isScanning {
                    HStack(spacing: 6) {
                        DishSpinner(size: 12)
                        Text("Scanning…")
                    }
                } else {
                    Text("Scan")
                }
            }
            .buttonStyle(DishOutlinedButtonStyle())
            .disabled(wifi.isScanning)
            Button(String(localized: "Done")) { dismiss() }
                .buttonStyle(DishOutlinedButtonStyle())
        }
        .padding(20)
    }

    // MARK: - Row model (known + newly-discovered merged)

    /// Either an existing `ConnectionSummary` (remembered or live) or a
    /// freshly-discovered server that isn't in the summary list yet.
    private enum Row {
        case known(ConnectionSummary)
        case discovered(DiscoveredServer)

        var key: String {
            switch self {
            case let .known(summary): summary.id
            case let .discovered(server): server.id
            }
        }
    }

    private var combinedRows: [Row] {
        let knownIds = Set(model.connections.map(\.id))
        var rows: [Row] = model.connections.map { .known($0) }
        for server in wifi.discoveredServers where !knownIds.contains(server.id) {
            rows.append(.discovered(server))
        }
        return rows
    }

    @ViewBuilder
    private func rowView(_ row: Row) -> some View {
        switch row {
        case let .known(summary): knownRow(summary)
        case let .discovered(server): discoveredRow(server)
        }
    }

    // MARK: - Row views

    private func knownRow(_ summary: ConnectionSummary) -> some View {
        HStack(spacing: 10) {
            // State-aware satellite glyph + status dot in one ZStack. Each
            // row in this view IS a satellite server the laptop is reaching
            // out to, so the silhouette is the satellite — not the dish on
            // the laptop's end. The coloured dot stays as a secondary tonal
            // cue in the corner (live=green, connecting=primary, else=muted),
            // matching the dish-android row_connection.xml layout.
            ZStack(alignment: .bottomTrailing) {
                BrandIcon.satellite(for: summary.live, size: 28)
                StatusDot(color: dotColor(for: summary))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(summary.label)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(DishTheme.onSurface)
                Text(summary.detail)
                    .font(.system(size: 11))
                    .foregroundColor(DishTheme.muted)
                Text(statusText(for: summary))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(DishTheme.muted)
            }
            Spacer()
            // The pairing-in-flight + .connecting loaders both live *inside*
            // `primaryButton` now (DishSpinner accompanies the label) so we
            // don't double up with a standalone row-level spinner here. The
            // disabled-button styling (opacity 0.4) signals non-tappable.
            primaryButton(for: summary)
            Button(String(localized: "Forget")) { model.forget(summary.id) }
                .buttonStyle(DishOutlinedButtonStyle())
        }
        .rowBackground()
    }

    private func discoveredRow(_ server: DiscoveredServer) -> some View {
        // A freshly-discovered (unpaired) row: tapping Connect runs the same
        // pair → openSession pipeline as a known row, so it gets the same
        // in-button spinner + disabled treatment while pairing is in flight.
        let pairing = wifi.pairingInFlight.contains(server.id)
        return HStack(spacing: 10) {
            ZStack(alignment: .bottomTrailing) {
                BrandIcon(kind: .satellite, state: .default, size: 28)
                StatusDot(color: DishTheme.muted)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(server.name.isEmpty ? server.ip : server.name)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(DishTheme.onSurface)
                Text("\(server.ip) • UDP \(server.udpPort)")
                    .font(.system(size: 11))
                    .foregroundColor(DishTheme.muted)
                Text("Found · \(server.source.label)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(DishTheme.muted)
            }
            Spacer()
            Button {
                model.connect(server)
            } label: {
                if pairing {
                    HStack(spacing: 6) {
                        DishSpinner(size: 12)
                        Text("Pairing…")
                    }
                } else {
                    Text("Connect")
                }
            }
            .buttonStyle(DishOutlinedButtonStyle())
            .disabled(pairing)
        }
        .rowBackground()
    }

    // `Text("…")` literals in this file rely on SwiftUI's implicit
    // `LocalizedStringKey` initializer to resolve through the catalog;
    // the chip / button text below ("Connecting…", "Pairing…", "Connect",
    // "Disconnect") all have catalog entries.

    @ViewBuilder
    private func primaryButton(for summary: ConnectionSummary) -> some View {
        // Two in-flight signals can apply to the primary action:
        //   1. `pairingInFlight` — POST /api/pair is running; the chip is still
        //      a resting state because openSession hasn't started yet.
        //   2. `.connecting` — pair succeeded, openSession is opening the UDP
        //      socket and running the connection handshake.
        // Both surface here as "spinner + label, button disabled" so the user
        // sees a continuous working state through both stages of a fresh
        // Connect rather than a brief un-disabled gap between them.
        let pairing = wifi.pairingInFlight.contains(summary.id)
        switch summary.live {
        case .connected, .unstable:
            Button("Disconnect") { model.disconnect(summary.id) }
                .buttonStyle(DishOutlinedButtonStyle())
        case .connecting:
            Button {
                // no-op: disabled
            } label: {
                HStack(spacing: 6) {
                    DishSpinner(size: 12)
                    Text("Connecting…")
                }
            }
            .buttonStyle(DishOutlinedButtonStyle())
            .disabled(true)
        case .found, .stale, .saved, .ready:
            Button {
                if let remembered = wifi.remembered().first(where: { $0.id == summary.id }) {
                    model.connect(remembered.toDiscovered())
                }
            } label: {
                if pairing {
                    HStack(spacing: 6) {
                        DishSpinner(size: 12)
                        Text("Pairing…")
                    }
                } else {
                    Text("Connect")
                }
            }
            .buttonStyle(DishOutlinedButtonStyle())
            .disabled(pairing)
        }
    }

    /// User-facing chip text per LinkState. The internal enum names (live /
    /// linking / faltering) live one layer down in `SessionState`; this layer's
    /// job is to map every LinkState — including the discovery/pairing axis
    /// values the wire layer doesn't know about — to a noun (resting) or
    /// verb-with-ellipsis (transient) per the shared nomenclature.
    private func statusText(for summary: ConnectionSummary) -> String {
        let base = switch summary.live {
        case .found: String(localized: "Found")
        case .stale: String(localized: "Needs pairing")
        case .saved: String(localized: "Offline")
        case .ready: String(localized: "Ready")
        case .connecting: String(localized: "Connecting…")
        case .connected: String(localized: "Online")
        case .unstable: String(localized: "Unsteady")
        }
        // One-way latency readout beside the live chip (gap G13). Numeric +
        // SI unit, deliberately unlocalized — same convention as the
        // "IP • UDP port" detail line above it.
        if let ms = summary.latencyMs, summary.live == .connected || summary.live == .unstable {
            return base + String(format: " · %.1f ms", ms)
        }
        return base
    }

    /// Color map keyed on LinkState. The "Unsteady" amber would ideally be a
    /// distinct color but we share `.primary` with "Connecting…" until a real
    /// amber lands in DishTheme — both signal "transient, watch this row" so
    /// the conflation is acceptable.
    private func dotColor(for summary: ConnectionSummary) -> Color {
        switch summary.live {
        case .connected: DishTheme.success
        case .connecting, .unstable: DishTheme.primary
        case .found, .stale, .saved, .ready: DishTheme.muted
        }
    }
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
