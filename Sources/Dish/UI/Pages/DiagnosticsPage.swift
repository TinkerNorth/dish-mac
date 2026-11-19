// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishEngine
import SwiftUI

/// Diagnostics: what the app sees right now. Each satellite session's own
/// account of itself, each controller down to the wire, and the flight
/// recorder. Read-only: every figure is one the rest of the app already acts
/// on, not a second measurement. The source ticks while the page shows.
struct DiagnosticsPage: View {

    @EnvironmentObject var model: AppModel
    @EnvironmentObject var navigation: NavigationStore
    @Environment(\.pasteboard) private var pasteboard
    @State private var copied = false

    private let words = L10n.app

    private var state: DiagnosticsPageState {
        diagnosticsPageState(facts: model.shellFacts, mail: model.diagnosticsMailFacts)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(words.diagnosticsDetail)
                    .font(DishFont.detail)
                    .foregroundColor(DishTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                DiagnosticsMailSection(mail: state.mail)
                cardsSection(words.controllerDatabase, .cards([state.controllerDb]))
                cardsSection(words.hosts, state.hosts)
                cardsSection(words.controllers, state.pads)
                if let others = state.otherDevices {
                    otherDevicesSection(others)
                }
                eventsSection
            }
            .padding(DishSpace.page)
        }
        .onAppear { model.pageAppeared(.diagnostics) }
        .onDisappear { model.pageDisappeared(.diagnostics) }
    }

    private func cardsSection(_ title: String, _ cards: DiagnosticsCards) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: title)
            switch cards {
            case let .empty(note):
                emptyNote(note)
            case let .cards(cards):
                ForEach(cards) { card in
                    DiagnosticsCard(state: card, inspectLabel: words.inspectInput, inspect: inspect)
                }
            }
        }
    }

    /// The game devices GameController leaves out, under Android's note.
    private func otherDevicesSection(_ others: OtherInputDevicesState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: others.title)
            emptyNote(others.note)
            ForEach(others.cards) { card in
                DiagnosticsCard(state: card, inspectLabel: words.inspectInput, inspect: inspect)
                if let key = card.supportKey {
                    Button(words.helpSupportThisController) { helpSupport(key) }
                        .buttonStyle(DishOutlinedButtonStyle())
                }
            }
        }
    }

    /// The newest lines, newest first; Copy takes all of them, oldest first.
    private var eventsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                SectionHeader(title: words.events)
                Spacer()
                if copied {
                    Text(words.eventsCopied)
                        .font(DishFont.caption)
                        .foregroundColor(DishTheme.success)
                }
                Button(words.copy, action: copyEvents)
                    .buttonStyle(DishOutlinedButtonStyle())
                    .disabled(!state.canCopy)
            }
            ForEach(state.events) { event in
                Text(event.text)
                    .font(DishFont.mono)
                    .foregroundColor(DishTheme.onSurface)
                    .textSelection(.enabled)
            }
        }
    }

    private func emptyNote(_ text: String) -> some View {
        Text(text)
            .font(DishFont.detail)
            .foregroundColor(DishTheme.muted)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func inspect(_ slotId: String) {
        navigation.send(.push(.inspector(slotId: slotId)))
    }

    private func helpSupport(_ deviceKey: String) {
        navigation.send(.push(.helpSupport(deviceKey: deviceKey)))
    }

    private func copyEvents() {
        pasteboard.copy(diagnosticsTranscript(facts: model.shellFacts))
        copied = true
    }
}
