// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import SwiftUI

/// One boxed row of the diagram: the pad node, the wire, the host node or
/// the ghost "Bind…" card, and the binding strip under a hairline.
struct SignalRow: View {
    let state: HomeRowState
    let perform: (SlotChipAction, String) -> Void
    let edit: (String) -> Void
    let bind: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DishSpace.s5) {
            HStack(spacing: DishSpace.s6) {
                PadNode(state: state.pad)
                WireLine(label: state.wire.label, live: state.wire.live, transmitting: state.wire.transmitting, help: state.wire.help)
                    .frame(maxWidth: .infinity)
                destination
            }
            if case let .bound(_, strip) = state.destination {
                Divider()
                BindingStrip(
                    title: strip.title,
                    chips: strip.chips,
                    editTitle: strip.editTitle,
                    editHelp: strip.editHelp,
                    perform: performHere,
                    edit: editThisRow
                )
            }
        }
        .padding(DishSpace.s6)
        .background(signalRowFill(state.destination))
        .overlay(RoundedRectangle(cornerRadius: DishSize.cardRadius).stroke(DishTheme.cardStroke, lineWidth: DishSize.hairline))
        .clipShape(RoundedRectangle(cornerRadius: DishSize.cardRadius))
    }

    @ViewBuilder
    private var destination: some View {
        switch state.destination {
        case let .bound(host, _):
            HostNode(state: host)
        case let .ghost(card):
            Button(action: bindThisRow) {
                ActionCardLabel(title: card.title, subtitle: card.subtitle, plus: false)
            }
            .buttonStyle(.plain)
        }
    }

    private func editThisRow() {
        edit(state.id)
    }

    private func bindThisRow() {
        bind(state.id)
    }

    private func performHere(_ action: SlotChipAction) {
        perform(action, state.id)
    }
}

/// The "Set up a controller" invitation under the rows.
struct SetUpRow: View {
    let state: SetUpCardState
    let open: () -> Void

    var body: some View {
        HStack(spacing: DishSpace.s6) {
            Button(action: open) {
                ActionCardLabel(title: state.title, subtitle: state.subtitle, plus: true)
            }
            .buttonStyle(.plain)
            WireLine(label: "", live: false, showsGlyph: false)
                .frame(maxWidth: .infinity)
            Spacer()
                .frame(minWidth: DishSize.nodeMinWidth)
        }
    }
}

private struct PadNode: View {
    let state: PadNodeState

    var body: some View {
        HStack(spacing: DishSpace.s4) {
            BrandIcon(kind: .pad, state: .default, size: ConnectionRowParts.glyphSize)
            VStack(alignment: .leading, spacing: DishSpace.s1) {
                Text(state.name)
                    .font(DishFont.body)
                    .foregroundColor(DishTheme.onSurface)
                    .lineLimit(1)
                Text(state.detail)
                    .font(DishFont.caption)
                    .foregroundColor(DishTheme.muted)
                    .lineLimit(1)
            }
        }
        .help(state.name)
        .nodeBox()
    }
}

private struct HostNode: View {
    let state: HostNodeState

    var body: some View {
        HStack(spacing: DishSpace.s4) {
            glyph
            StatusDot(color: state.dot)
            VStack(alignment: .leading, spacing: DishSpace.s1) {
                Text(state.name)
                    .font(DishFont.body)
                    .foregroundColor(DishTheme.onSurface)
                    .lineLimit(1)
                Text(state.detail)
                    .font(DishFont.caption)
                    .foregroundColor(DishTheme.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: DishSpace.s2)
            StateChip(text: state.chip.text, color: state.chip.color)
        }
        .help(state.name)
        .nodeBox()
    }

    @ViewBuilder
    private var glyph: some View {
        switch state.glyph {
        case let .satellite(iconState):
            BrandIcon(kind: .satellite, state: iconState, size: ConnectionRowParts.glyphSize)
        case .moonlight:
            Image(systemName: "desktopcomputer")
                .font(DishFont.title)
                .foregroundColor(DishTheme.muted)
                .frame(width: ConnectionRowParts.glyphSize, height: ConnectionRowParts.glyphSize)
        }
    }
}

/// A node's dashed placeholder face: the ghost "Bind…" card and the "Set up
/// a controller" invitation.
private struct ActionCardLabel: View {
    let title: String
    let subtitle: String
    let plus: Bool

    var body: some View {
        HStack(spacing: DishSpace.s4) {
            if plus {
                Image(systemName: "plus.circle")
                    .font(DishFont.title)
                    .foregroundColor(DishTheme.primary)
            }
            VStack(alignment: .leading, spacing: DishSpace.s1) {
                Text(title)
                    .font(DishFont.body)
                    .foregroundColor(DishTheme.primary)
                Text(subtitle)
                    .font(DishFont.caption)
                    .foregroundColor(DishTheme.muted)
            }
            Spacer(minLength: 0)
        }
        .padding(DishSpace.s5)
        .frame(minWidth: DishSize.nodeMinWidth, alignment: .leading)
        .overlay(
            RoundedRectangle(cornerRadius: DishSize.cardRadius)
                .stroke(DishTheme.outline, style: StrokeStyle(lineWidth: DishSize.hairline, dash: [DishSize.wireDash]))
        )
        .contentShape(Rectangle())
    }
}

private extension View {
    /// A node's box on the diagram: outlined, never narrower than its floor.
    func nodeBox() -> some View {
        padding(DishSpace.s5)
            .frame(minWidth: DishSize.nodeMinWidth, alignment: .leading)
            .overlay(RoundedRectangle(cornerRadius: DishSize.cardRadius).stroke(DishTheme.cardStroke, lineWidth: DishSize.hairline))
    }
}
