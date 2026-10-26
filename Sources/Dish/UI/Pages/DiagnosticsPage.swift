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
        diagnosticsPageState(facts: model.shellFacts)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(words.diagnosticsDetail)
                    .font(DishFont.detail)
                    .foregroundColor(DishTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                cardsSection(words.hosts, state.hosts)
                cardsSection(words.controllers, state.pads)
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

    private func copyEvents() {
        pasteboard.copy(diagnosticsTranscript(facts: model.shellFacts))
        copied = true
    }
}

/// One card: a headline with its dot and chip, then one fact per line with
/// the key in a fixed left column so every card lines up.
private struct DiagnosticsCard: View {

    let state: DiagnosticsCardState
    let inspectLabel: String
    let inspect: (String) -> Void

    private static let keyColumn: CGFloat = 150

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if let dot = state.dot {
                    StatusDot(color: dot)
                }
                Text(state.title)
                    .font(DishFont.body)
                    .foregroundColor(DishTheme.onSurface)
                Spacer()
                if let chip = state.chip {
                    Text(chip)
                        .font(DishFont.monoChip)
                        .foregroundColor(DishTheme.muted)
                }
                if let slotId = state.inspects {
                    Button(inspectLabel) { inspect(slotId) }
                        .buttonStyle(DishOutlinedButtonStyle())
                }
            }
            ForEach(state.lines) { line in
                factLine(line)
            }
        }
        .padding(12)
        .background(DishTheme.surface)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(DishTheme.cardStroke, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func factLine(_ line: FactLine) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(line.key)
                .font(DishFont.caption)
                .foregroundColor(DishTheme.muted)
                .frame(width: Self.keyColumn, alignment: .leading)
            Text(line.value)
                .font(DishFont.mono)
                .foregroundColor(DishTheme.onSurface)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}
