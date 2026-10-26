// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishEngine
import SwiftUI

/// PAIRED: the empty state, or a card per remembered satellite.
struct PairedSection: View {
    let state: PairedSectionState

    var body: some View {
        switch state {
        case let .empty(card):
            EmptyStateCard(title: card.title, message: card.message, hint: card.hint)
        case let .cards(cards):
            ForEach(cards) { card in
                PairedCard(state: card)
            }
        }
    }
}

/// One remembered satellite: who and where it is, how its link stands,
/// what it carries, and its one primary action with Forget behind ⋯. A
/// revoked key's Pair… opens the pairing card under it.
private struct PairedCard: View {

    @EnvironmentObject var model: AppModel
    let state: PairedCardState

    var body: some View {
        VStack(alignment: .leading, spacing: DishSpace.s6) {
            header
            CarryingManifest(state: state.carrying)
            HStack(spacing: DishSpace.s4) {
                Spacer()
                ForEach(state.actions) { action in
                    actionButton(action)
                }
                RowMenu(state: state.menu, forget: requestForget)
            }
            if let pairing = state.pairing {
                PairingCardHost(server: pairing.server, attempt: pairing.attempt)
            }
        }
        .settingsCard()
    }

    private var header: some View {
        HStack(spacing: DishSpace.s5) {
            BrandIcon(kind: .satellite, state: state.glyph, size: ConnectionRowParts.glyphSize)
            StatusDot(color: state.dot)
            Text(state.title)
                .font(DishFont.body)
                .foregroundColor(DishTheme.onSurface)
                .lineLimit(1)
            Spacer()
            Text(state.address)
                .font(DishFont.monoChip)
                .foregroundColor(DishTheme.muted)
            if let latency = state.latency {
                Text(latency)
                    .font(DishFont.monoChip)
                    .foregroundColor(DishTheme.primary)
            }
            ChipRow(chips: state.chips)
        }
    }

    private func actionButton(_ action: SatelliteActionState) -> some View {
        Button {
            model.perform(action.kind, on: state.id)
        } label: {
            HStack(spacing: DishSpace.s3) {
                if action.working {
                    DishSpinner(size: DishSize.buttonSpinner)
                }
                Text(action.title)
            }
        }
        .buttonStyle(DishOutlinedButtonStyle())
        .disabled(!action.enabled)
    }

    private func requestForget() {
        model.requestForget(state.id)
    }
}

/// The read-only manifest of what the host carries, never a link: a host
/// carries up to four slots, so no line maps to one binding.
private struct CarryingManifest: View {
    let state: CarryingState

    var body: some View {
        VStack(alignment: .leading, spacing: DishSpace.s2) {
            Text(state.title)
                .textCase(.uppercase)
                .font(DishFont.monoChip)
                .tracking(1)
                .foregroundColor(DishTheme.muted)
            if let empty = state.emptyLine {
                Text(empty)
                    .font(DishFont.caption)
                    .foregroundColor(DishTheme.muted)
            }
            ForEach(state.lines.indices, id: \.self) { index in
                Text(state.lines[index])
                    .font(DishFont.caption)
                    .foregroundColor(DishTheme.onSurface)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DishSpace.s5)
        .background(DishTheme.surfaceDim)
        .clipShape(RoundedRectangle(cornerRadius: DishSize.cardRadius))
    }
}
