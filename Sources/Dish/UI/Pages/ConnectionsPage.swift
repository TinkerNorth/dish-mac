// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishEngine
import SwiftUI

/// Connections: the inventory of satellites. It scans as it opens; FOUND
/// lists what the sweep heard with a Pair… button whose card opens under the
/// row; a row leads to the Moonlight hosts page; PAIRED holds a card per
/// remembered satellite with what it carries; an address field is the way
/// in when discovery is dead. Forget asks first.
struct ConnectionsPage: View {

    @EnvironmentObject var model: AppModel
    @EnvironmentObject var navigation: NavigationStore
    @State private var draft = ""

    private var state: ConnectionsPageState {
        let inputs = ConnectionsInputs(
            connections: model.connections,
            slots: model.slots,
            facts: model.shellFacts.connections,
            openPairing: model.openPairing
        )
        return connectionsPageState(inputs, draft: draft)
    }

    var body: some View {
        let state = state
        ScrollView {
            VStack(alignment: .leading, spacing: DishSpace.s8) {
                ScanHeader(
                    title: state.foundTitle,
                    scanTitle: state.scan.title,
                    scanEnabled: state.scan.enabled,
                    scanning: state.scan.showsBar,
                    scan: model.startScan
                )
                FoundSection(state: state.found)
                DoorRow(state: state.moonlightDoor, open: openMoonlightHosts)
                SectionHeader(title: state.pairedTitle)
                PairedSection(state: state.paired)
                AddressRow(state: state.address, draft: $draft, submit: submitAddress, dismiss: model.clearAddressError)
            }
            .padding(DishSpace.page)
        }
        .forgetConfirmation(state.forget, confirm: model.confirmForget, cancel: model.cancelForget)
        .onAppear { model.pageAppeared(.connections) }
        .onDisappear { model.pageDisappeared(.connections) }
    }

    private func openMoonlightHosts() {
        navigation.send(.push(.moonlightHosts))
    }

    private func submitAddress() {
        if model.addByAddress(.satellite, draft) { draft = "" }
    }
}

/// FOUND: the sweep's empty states, or a row per satellite it heard.
private struct FoundSection: View {

    @EnvironmentObject var model: AppModel
    @Environment(\.openURL) private var openURL
    let state: FoundSectionState

    var body: some View {
        switch state {
        case let .looking(card):
            EmptyStateCard(title: card.title, message: card.message, hint: card.hint)
        case let .nothing(nothing):
            EmptyStateCard(title: nothing.card.title, message: nothing.card.message, hint: nothing.card.hint) {
                Button(nothing.getApp) { open(nothing.getAppURL) }
                    .buttonStyle(DishOutlinedButtonStyle())
                Button(nothing.secondary, action: model.startScan)
                    .buttonStyle(DishOutlinedButtonStyle())
            }
        case let .rows(rows):
            ForEach(rows) { row in
                FoundRow(state: row)
            }
        }
    }

    private func open(_ url: URL?) {
        if let url { openURL(url) }
    }
}

/// A satellite the sweep heard that nothing remembers yet; its pairing card
/// opens under it.
private struct FoundRow: View {

    @EnvironmentObject var model: AppModel
    let state: FoundRowState

    var body: some View {
        VStack(alignment: .leading, spacing: DishSpace.s5) {
            HStack(spacing: DishSpace.s5) {
                BrandIcon(kind: .satellite, state: .default, size: ConnectionRowParts.glyphSize)
                StatusDot(color: DishTheme.muted)
                Text(state.title)
                    .font(DishFont.body)
                    .foregroundColor(DishTheme.onSurface)
                    .lineLimit(1)
                Spacer()
                Text(state.detail)
                    .font(DishFont.monoChip)
                    .foregroundColor(DishTheme.muted)
                ChipRow(chips: state.chips)
                Button(state.pairTitle, action: pair)
                    .buttonStyle(DishOutlinedButtonStyle())
                    .disabled(!state.pairEnabled)
            }
            if let pairing = state.pairing {
                PairingCardHost(server: pairing.server, attempt: pairing.attempt)
            }
        }
        .settingsCard()
    }

    private func pair() {
        model.beginPairing(serverId: state.id)
    }
}

/// A labelled doorway to another page.
private struct DoorRow: View {
    let state: DoorRowState
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack {
                RowText(title: state.title, detail: state.subtitle)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(DishFont.icon)
                    .foregroundColor(DishTheme.muted)
            }
            .contentShape(Rectangle())
            .settingsCard()
        }
        .buttonStyle(.plain)
    }
}

/// The satellite field at the foot of the page: IPv4, optionally with a port.
private struct AddressRow: View {
    let state: AddressFieldState
    @Binding var draft: String
    let submit: () -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DishSpace.s4) {
            HStack(spacing: DishSpace.s4) {
                TextField(state.placeholder, text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .font(DishFont.detail)
                    .onSubmit(submit)
                Button(state.addTitle, action: submit)
                    .buttonStyle(DishOutlinedButtonStyle())
                    .disabled(!state.canAdd)
            }
            if let error = state.error {
                ErrorBanner(message: error, onDismiss: dismiss)
            }
        }
    }
}
