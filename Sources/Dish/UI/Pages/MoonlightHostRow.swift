// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishEngine
import SwiftUI

/// One Moonlight host: its name and kind in words, its address, the tier,
/// trust and controller chips, why its session is not up, the app it
/// starts, the way out of where it stands, Forget behind ⋯, and the PIN
/// card while it pairs.
struct MoonlightHostRow: View {

    @EnvironmentObject var model: AppModel
    let state: MoonlightHostRowState

    var body: some View {
        VStack(alignment: .leading, spacing: DishSpace.s5) {
            header
            if let line = state.statusLine {
                Text(line)
                    .font(DishFont.caption)
                    .foregroundColor(DishTheme.muted)
            }
            if let app = state.app {
                MoonlightAppPicker(state: app, pick: pickApp)
            }
            HStack(spacing: DishSpace.s4) {
                Spacer()
                ForEach(state.actions) { action in
                    Button(action.title) { model.perform(action.kind, onHost: state.id) }
                        .buttonStyle(DishOutlinedButtonStyle())
                        .disabled(!action.enabled)
                }
                if let menu = state.menu {
                    RowMenu(state: menu, forget: requestForget)
                }
            }
            if let pin = state.pin {
                MoonlightPinCard(state: pin, cancel: cancelPairing, newCode: newCode)
            }
        }
        .settingsCard()
    }

    private var header: some View {
        HStack(spacing: DishSpace.s5) {
            Image(systemName: "desktopcomputer")
                .font(DishFont.title)
                .foregroundColor(DishTheme.muted)
                .frame(width: ConnectionRowParts.glyphSize, height: ConnectionRowParts.glyphSize)
            StatusDot(color: state.dot)
            VStack(alignment: .leading, spacing: DishSpace.s1) {
                Text(state.title)
                    .font(DishFont.body)
                    .foregroundColor(DishTheme.onSurface)
                    .lineLimit(1)
                Text(state.kindLine)
                    .font(DishFont.caption)
                    .foregroundColor(DishTheme.muted)
            }
            Spacer()
            Text(state.address)
                .font(DishFont.monoChip)
                .foregroundColor(DishTheme.muted)
            ChipRow(chips: state.chips)
        }
    }

    private func pickApp(_ appId: String) {
        model.pickMoonlightApp(state.id, appId: appId)
    }

    private func requestForget() {
        model.requestForget(state.id)
    }

    private func cancelPairing() {
        model.cancelMoonlightPairing(state.id)
    }

    private func newCode() {
        model.newMoonlightCode(state.id)
    }
}

/// The app a host's session starts, shared by every pad on the host.
private struct MoonlightAppPicker: View {
    let state: AppPickerState
    let pick: (String) -> Void

    private static let pickerWidth: CGFloat = 220

    private var selection: Binding<String> {
        Binding(get: picked, set: pick)
    }

    var body: some View {
        HStack(spacing: DishSpace.s4) {
            Text(state.label)
                .font(DishFont.caption)
                .foregroundColor(DishTheme.muted)
            Picker(state.label, selection: selection) {
                ForEach(state.options) { option in
                    Text(option.title).tag(option.id)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: Self.pickerWidth)
            if let note = state.note {
                Text(note)
                    .font(DishFont.microRegular)
                    .foregroundColor(DishTheme.muted)
            }
        }
    }

    private func picked() -> String {
        state.selection
    }
}

/// The PIN the other way round from a satellite's: the dish minted it, the
/// user types it into the host's own page, and the card waits on that. It
/// goes when the host paired or refused; Cancel ends the exchange with
/// nothing written, and New code mints another.
private struct MoonlightPinCard: View {
    let state: MoonlightPinCardState
    let cancel: () -> Void
    let newCode: () -> Void

    private static let barWidth: CGFloat = 60

    var body: some View {
        VStack(alignment: .leading, spacing: DishSpace.s5) {
            Text(state.title)
                .font(DishFont.body)
                .foregroundColor(DishTheme.onSurface)
            Text(state.prompt)
                .font(DishFont.detail)
                .foregroundColor(DishTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
            PinCells(digits: state.cells, stroke: DishTheme.outline, ink: DishTheme.primary)
                .frame(maxWidth: .infinity)
                .textSelection(.enabled)
            HStack(spacing: DishSpace.s5) {
                DishBar(width: Self.barWidth)
                Text(state.waiting)
                    .font(DishFont.detail)
                    .foregroundColor(DishTheme.muted)
                Spacer()
                Button(state.cancel, action: cancel)
                    .buttonStyle(DishOutlinedButtonStyle())
                Button(state.newCode, action: newCode)
                    .buttonStyle(DishOutlinedButtonStyle())
            }
        }
        .padding(DishSpace.s6)
        .background(DishTheme.surfaceDim)
        .clipShape(RoundedRectangle(cornerRadius: DishSize.cardRadius))
    }
}
