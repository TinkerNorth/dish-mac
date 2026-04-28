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
                    SectionHeader(title: "WI-FI SERVERS")
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
        }
        .frame(minWidth: 480, minHeight: 540)
        .background(DishTheme.background)
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
            case .known(let c):       return c.id
            case .discovered(let s):  return s.id
            }
        }
    }

    private var combinedRows: [Row] {
        let knownIds = Set(model.connections.map { $0.id })
        var rows: [Row] = model.connections.map { .known($0) }
        for s in wifi.discoveredServers where !knownIds.contains(s.id) {
            rows.append(.discovered(s))
        }
        return rows
    }

    @ViewBuilder
    private func rowView(_ row: Row) -> some View {
        switch row {
        case .known(let c):      knownRow(c)
        case .discovered(let s): discoveredRow(s)
        }
    }

    // MARK: - Row views

    private func knownRow(_ c: ConnectionSummary) -> some View {
        HStack(spacing: 10) {
            StatusDot(color: dotColor(for: c))
            VStack(alignment: .leading, spacing: 2) {
                Text(c.label)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(DishTheme.onSurface)
                Text(c.detail)
                    .font(.system(size: 11))
                    .foregroundColor(DishTheme.muted)
                Text(statusText(for: c))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(DishTheme.muted)
            }
            Spacer()
            primaryButton(for: c)
            Button("Forget") { model.forget(c.id) }
                .buttonStyle(DishOutlinedButtonStyle())
        }
        .rowBackground()
    }

    private func discoveredRow(_ s: DiscoveredServer) -> some View {
        HStack(spacing: 10) {
            StatusDot(color: DishTheme.muted)
            VStack(alignment: .leading, spacing: 2) {
                Text(s.name.isEmpty ? s.ip : s.name)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(DishTheme.onSurface)
                Text("\(s.ip) • UDP \(s.udpPort)")
                    .font(.system(size: 11))
                    .foregroundColor(DishTheme.muted)
                Text("Discovered")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(DishTheme.muted)
            }
            Spacer()
            Button("Connect") { model.connect(s) }
                .buttonStyle(DishOutlinedButtonStyle())
        }
        .rowBackground()
    }

    @ViewBuilder
    private func primaryButton(for c: ConnectionSummary) -> some View {
        switch c.live {
        case .connected:
            Button("Disconnect") { model.disconnect(c.id) }
                .buttonStyle(DishOutlinedButtonStyle())
        case .connecting:
            Button("Connecting…") {}
                .buttonStyle(DishOutlinedButtonStyle())
                .disabled(true)
        case .idle:
            Button("Connect") {
                if let r = wifi.remembered().first(where: { $0.id == c.id }) {
                    model.connect(r.toDiscovered())
                }
            }
            .buttonStyle(DishOutlinedButtonStyle())
        }
    }

    private func statusText(for c: ConnectionSummary) -> String {
        switch c.live {
        case .connected:  return "Connected"
        case .connecting: return "Connecting"
        case .idle:       return "Idle"
        }
    }

    private func dotColor(for c: ConnectionSummary) -> Color {
        switch c.live {
        case .connected:  return DishTheme.success
        case .connecting: return DishTheme.primary
        case .idle:       return DishTheme.muted
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
