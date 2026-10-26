// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishEngine
import SwiftUI

/// Moonlight hosts, pushed from Connections: the GameStream hosts (Sunshine,
/// Apollo, Wolf) apart from the satellites, because they pair the other way
/// round. A row carries a trust word, never a liveness light; the PIN the
/// dish mints shows in the row that asked for it; a host mDNS misses is
/// added by address in an inline form. Forget asks first.
struct MoonlightHostsPage: View {

    @EnvironmentObject var model: AppModel
    @State private var draft = ""
    @State private var adding = false

    private var state: MoonlightHostsPageState {
        let inputs = MoonlightHostsInputs(
            connections: model.connections,
            slots: model.slots,
            facts: model.shellFacts.connections,
            pin: model.moonlightPin
        )
        return moonlightHostsPageState(inputs, draft: draft)
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
                    scan: model.scanMoonlightHosts,
                    extra: ScanHeader.Extra(title: state.addTitle, action: openForm)
                )
                if adding {
                    AddHostForm(state: state.addForm, draft: $draft, submit: submit, cancel: closeForm, dismiss: model.clearAddressError)
                }
                MoonlightList(state: state.list, addByAddress: openForm)
            }
            .padding(DishSpace.page)
        }
        .forgetConfirmation(state.forget, confirm: model.confirmForget, cancel: model.cancelForget)
        .onAppear { model.pageAppeared(.moonlightHosts) }
        .onDisappear { model.pageDisappeared(.moonlightHosts) }
    }

    private func openForm() {
        adding = true
    }

    private func closeForm() {
        adding = false
        draft = ""
        model.clearAddressError()
    }

    private func submit() {
        if model.addByAddress(.moonlight, draft) { closeForm() }
    }
}

/// The hosts, or the sweep's empty states with their ways forward.
private struct MoonlightList: View {

    @Environment(\.openURL) private var openURL
    let state: MoonlightListState
    let addByAddress: () -> Void

    var body: some View {
        switch state {
        case let .looking(card):
            EmptyStateCard(title: card.title, message: card.message, hint: card.hint)
        case let .nothing(nothing):
            EmptyStateCard(title: nothing.card.title, message: nothing.card.message, hint: nothing.card.hint) {
                Button(nothing.getApp) { open(nothing.getAppURL) }
                    .buttonStyle(DishOutlinedButtonStyle())
                Button(nothing.secondary, action: addByAddress)
                    .buttonStyle(DishOutlinedButtonStyle())
            }
        case let .rows(rows):
            ForEach(rows) { row in
                MoonlightHostRow(state: row)
            }
        }
    }

    private func open(_ url: URL?) {
        if let url { openURL(url) }
    }
}

/// The discovery fallback, inline: mDNS does not cross every subnet, so a
/// host can always be reached by typing where it lives.
private struct AddHostForm: View {
    let state: AddHostFormState
    @Binding var draft: String
    let submit: () -> Void
    let cancel: () -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DishSpace.s5) {
            Text(state.heading)
                .font(DishFont.body)
                .foregroundColor(DishTheme.onSurface)
            Text(state.message)
                .font(DishFont.detail)
                .foregroundColor(DishTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
            TextField(state.field.placeholder, text: $draft)
                .textFieldStyle(.roundedBorder)
                .font(DishFont.detail)
                .onSubmit(submit)
            if let error = state.field.error {
                ErrorBanner(message: error, onDismiss: dismiss)
            }
            HStack {
                Spacer()
                Button(state.cancel, action: cancel)
                    .buttonStyle(DishOutlinedButtonStyle())
                Button(state.field.addTitle, action: submit)
                    .buttonStyle(DishOutlinedButtonStyle())
                    .disabled(!state.field.canAdd)
            }
        }
        .padding(DishSpace.s6)
        .background(DishTheme.surfaceDim)
        .clipShape(RoundedRectangle(cornerRadius: DishSize.cardRadius))
    }
}
