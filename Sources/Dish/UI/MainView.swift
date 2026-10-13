// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishEngine
import SwiftUI

/// The dashboard window: the status row, the controller slot list, and the
/// Manage button that presents `ConnectionsView` in a sheet.
struct MainView: View {

    @EnvironmentObject var model: AppModel
    @EnvironmentObject var wifi: WifiConnectionManager
    @State private var showConnections = false
    @State private var showSettings = false

    private let words = L10n.app

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider().background(DishTheme.outline)
            slotSection
            Spacer(minLength: 0)
            if let failure = model.lastFailure {
                ErrorBanner(message: failureText(failure)) { model.clearFailure() }
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
        liveConnections(model.connections).count
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ZStack(alignment: .bottomTrailing) {
                    BrandIcon(kind: .satellite, state: dashboardIconState(liveCount: liveCount), size: 28)
                    StatusDot(color: dashboardAccent(liveCount: liveCount))
                }
                Text(dashboardStatusText(model.connections))
                    .font(DishFont.title)
                    .foregroundColor(dashboardAccent(liveCount: liveCount))
                if let chip = micIndicatorChip(model.micIndicator) {
                    Button {
                        model.toggleAllMics()
                    } label: {
                        CapabilityChipView(chip: chip)
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                        .font(DishFont.icon)
                        .foregroundColor(DishTheme.primary)
                }
                .buttonStyle(.plain)
                .help(words.settings)
                Button(words.manage) { showConnections = true }
                    .buttonStyle(DishOutlinedButtonStyle())
            }
            Text(dashboardSummaryText(model.connections))
                .font(DishFont.detail)
                .foregroundColor(DishTheme.muted)
        }
    }

    // MARK: - Slot section

    private var slotSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                SectionHeader(title: words.controllersSection)
                if wifi.anyControllerRegistering {
                    ProgressView()
                        .controlSize(.small)
                        .progressViewStyle(.circular)
                }
                Spacer()
            }
            if model.slots.isEmpty {
                Text(words.noControllersConnected)
                    .font(DishFont.detail)
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
