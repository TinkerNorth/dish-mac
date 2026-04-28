// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import SwiftUI

/// Dashboard window — mirrors `activity_main.xml`. Top status row, controller
/// slot list, telemetry footer, and a "Manage connections" button that
/// presents `ConnectionsView` in a sheet.
struct MainView: View {

    @EnvironmentObject var model: AppModel
    @EnvironmentObject var telemetry: TelemetryTracker
    @State private var showConnections = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider().background(DishTheme.outline)
            slotSection
            Spacer(minLength: 0)
            telemetryFooter
        }
        .padding(20)
        .sheet(isPresented: $showConnections) {
            ConnectionsView()
                .environmentObject(model)
                .environmentObject(model.wifi)
        }
        .sheet(item: $model.pairingTarget) { server in
            PairingSheet(server: server).environmentObject(model)
        }
        .alert("Error",
               isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
               ),
               presenting: model.errorMessage) { _ in
            Button("OK") { model.errorMessage = nil }
        } message: { msg in
            Text(msg)
        }
    }

    // MARK: - Header

    private var liveCount: Int {
        model.connections.filter { $0.live == .connected }.count
    }

    private var statusText: String {
        let live = liveCount
        let total = model.connections.count
        switch (live, total) {
        case (0, 0): return "No connections yet"
        case (0, _): return "\(total) remembered"
        case (1, _): return model.connections.first { $0.live == .connected }?.label ?? ""
        default:     return "\(live) active connections"
        }
    }

    private var summaryText: String {
        let live = liveCount
        let total = model.connections.count
        if live == 0 && total == 0 { return "Tap Manage to add one" }
        if live == 0 { return "\(total) remembered" }
        return "\(live) of \(total) connected"
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                StatusDot(color: liveCount > 0 ? DishTheme.success : DishTheme.muted)
                Text(statusText)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(liveCount > 0 ? DishTheme.success : DishTheme.muted)
                Spacer()
                Button("Manage") { showConnections = true }
                    .buttonStyle(DishOutlinedButtonStyle())
            }
            Text(summaryText)
                .font(.system(size: 12))
                .foregroundColor(DishTheme.muted)
        }
    }

    // MARK: - Slot section

    private var slotSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "CONTROLLERS")
            if model.slots.isEmpty {
                Text("No controllers connected")
                    .font(.system(size: 12))
                    .foregroundColor(DishTheme.muted)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(model.slots) { slot in
                            SlotCard(slot: slot)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Telemetry footer

    private var telemetryFooter: some View {
        HStack {
            Text("events/s \(telemetry.events)")
            Text("sends/s \(telemetry.sends)")
            Spacer()
            Text("total \(telemetry.totalSent)")
        }
        .font(.system(size: 10, weight: .regular, design: .monospaced))
        .foregroundColor(DishTheme.muted)
    }
}
