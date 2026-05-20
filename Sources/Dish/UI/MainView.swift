// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import SwiftUI

/// Dashboard window — mirrors `activity_main.xml`. Top status row, controller
/// slot list, and a "Manage connections" button that presents
/// `ConnectionsView` in a sheet.
struct MainView: View {

    @EnvironmentObject var model: AppModel
    @EnvironmentObject var wifi: WifiConnectionManager
    @State private var showConnections = false
    @State private var showSettings = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider().background(DishTheme.outline)
            slotSection
            Spacer(minLength: 0)
            if let msg = model.errorMessage {
                ErrorBanner(message: msg) { model.errorMessage = nil }
            }
        }
        .padding(20)
        .sheet(isPresented: $showConnections) {
            ConnectionsView()
                .environmentObject(model)
                .environmentObject(model.wifi)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environmentObject(model.settings)
        }
        .sheet(item: $model.pairingTarget) { server in
            PairingSheet(server: server)
                .environmentObject(model)
                .environmentObject(model.wifi)
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
        case (0, _): return "\(total) paired"
        case (1, _): return model.connections.first { $0.live == .connected }?.label ?? ""
        default: return "\(live) active connections"
        }
    }

    private var summaryText: String {
        let live = liveCount
        let total = model.connections.count
        if live == 0, total == 0 { return "Tap Manage to add one" }
        if live == 0 { return "\(total) paired" }
        return "\(live) of \(total) online"
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                StatusDot(color: liveCount > 0 ? DishTheme.success : DishTheme.muted)
                Text(statusText)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(liveCount > 0 ? DishTheme.success : DishTheme.muted)
                Spacer()
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 14))
                        .foregroundColor(DishTheme.primary)
                }
                .buttonStyle(.plain)
                .help("Settings")
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
            HStack(spacing: 8) {
                SectionHeader(title: "CONTROLLERS")
                if wifi.anyControllerRegistering {
                    ProgressView()
                        .controlSize(.small)
                        .progressViewStyle(.circular)
                }
                Spacer()
            }
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
}
