// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import SwiftUI

/// Connection-management sheet. Mirrors `ConnectionsActivity` (WiFi-only):
/// scan → pair → connect, plus forget for remembered entries.
struct ConnectionsView: View {

    @EnvironmentObject var model: AppModel
    @EnvironmentObject var wifi: WifiConnectionManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().background(DishTheme.outline)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 8) {
                        SectionHeader(title: "WI-FI SERVERS")
                        if wifi.isScanning {
                            ProgressView()
                                .controlSize(.small)
                                .progressViewStyle(.circular)
                        }
                        Spacer()
                    }
                    if combinedRows.isEmpty {
                        Text("Press Scan to look for servers on your LAN")
                            .font(.system(size: 12))
                            .foregroundColor(DishTheme.muted)
                            .padding(.vertical, 6)
                    } else {
                        ForEach(combinedRows, id: \.key) { row in
                            rowView(row)
                        }
                    }
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

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("Connections")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(DishTheme.onSurface)
            Spacer()
            Button(wifi.isScanning ? "Scanning…" : "Scan") {
                model.startScan()
            }
            .buttonStyle(DishOutlinedButtonStyle())
            .disabled(wifi.isScanning)
            Button("Done") { dismiss() }
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
            StatusDot(color: dotColor(for: summary))
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
            if wifi.pairingInFlight.contains(summary.id) {
                ProgressView()
                    .controlSize(.small)
                    .progressViewStyle(.circular)
            }
            primaryButton(for: summary)
            Button("Forget") { model.forget(summary.id) }
                .buttonStyle(DishOutlinedButtonStyle())
        }
        .rowBackground()
    }

    private func discoveredRow(_ server: DiscoveredServer) -> some View {
        HStack(spacing: 10) {
            StatusDot(color: DishTheme.muted)
            VStack(alignment: .leading, spacing: 2) {
                Text(server.name.isEmpty ? server.ip : server.name)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(DishTheme.onSurface)
                Text("\(server.ip) • UDP \(server.udpPort)")
                    .font(.system(size: 11))
                    .foregroundColor(DishTheme.muted)
                Text("Discovered")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(DishTheme.muted)
            }
            Spacer()
            Button("Connect") { model.connect(server) }
                .buttonStyle(DishOutlinedButtonStyle())
        }
        .rowBackground()
    }

    @ViewBuilder
    private func primaryButton(for summary: ConnectionSummary) -> some View {
        switch summary.live {
        case .connected:
            Button("Disconnect") { model.disconnect(summary.id) }
                .buttonStyle(DishOutlinedButtonStyle())
        case .connecting:
            Button("Connecting…") {}
                .buttonStyle(DishOutlinedButtonStyle())
                .disabled(true)
        case .idle:
            Button("Connect") {
                if let remembered = wifi.remembered().first(where: { $0.id == summary.id }) {
                    model.connect(remembered.toDiscovered())
                }
            }
            .buttonStyle(DishOutlinedButtonStyle())
        }
    }

    private func statusText(for summary: ConnectionSummary) -> String {
        switch summary.live {
        case .connected: "Connected"
        case .connecting: "Connecting"
        case .idle: "Idle"
        }
    }

    private func dotColor(for summary: ConnectionSummary) -> Color {
        switch summary.live {
        case .connected: DishTheme.success
        case .connecting: DishTheme.primary
        case .idle: DishTheme.muted
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
