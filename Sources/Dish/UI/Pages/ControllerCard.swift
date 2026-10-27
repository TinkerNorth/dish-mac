// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import SwiftUI

/// One pad on Controllers: its dot, name, player number and link, the
/// binding's hand-off, its capability chips, the microphone's control, its
/// motion rate, its input path with the "Not responding?" check, and the
/// way to its dead zones. The outline lights while the pad reports input.
struct ControllerCard: View {

    struct Actions {
        let configure: (String) -> Void
        let deadZones: (String) -> Void
        let setMicMuted: (Bool, String) -> Void
        let checkInput: (String) -> Void
        let pickPath: (InputSource, String) -> Void
        let helpSupport: (String) -> Void
    }

    let state: ControllerCardState
    let actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: DishSpace.s5) {
            HStack(spacing: DishSpace.s4) {
                StatusDot(color: state.dot)
                Text(state.name)
                    .font(DishFont.body)
                    .foregroundColor(DishTheme.onSurface)
                    .lineLimit(1)
                if let player = state.path?.player {
                    Text(player)
                        .font(DishFont.monoChip)
                        .foregroundColor(DishTheme.muted)
                }
                Spacer(minLength: DishSpace.s4)
                Text(state.link)
                    .font(DishFont.mono)
                    .foregroundColor(DishTheme.muted)
                binding
            }
            FlowLayout(spacing: DishSpace.s3) {
                ForEach(state.chips) { chip in
                    CapabilityChip(text: chip.text, look: chip.look, help: chip.help)
                }
                if let mic = state.mic {
                    Button(mic.title, action: toggleMic)
                        .buttonStyle(DishOutlinedButtonStyle())
                        .help(mic.help)
                        .accessibilityLabel(mic.help)
                }
                if let motion = state.motionRate {
                    Text(motion)
                        .font(DishFont.mono)
                        .foregroundColor(DishTheme.muted)
                }
            }
            if let path = state.path {
                PadPathSection(state: path, actions: pathActions)
            }
            Button(state.deadZones, action: openDeadZones)
                .buttonStyle(DishOutlinedButtonStyle())
        }
        .padding(DishSpace.s6)
        .background(DishTheme.surface)
        .overlay(RoundedRectangle(cornerRadius: DishSize.cardRadius).stroke(state.stroke, lineWidth: DishSize.hairline))
        .animation(.easeOut(duration: 0.2), value: state.stroke)
        .clipShape(RoundedRectangle(cornerRadius: DishSize.cardRadius))
    }

    @ViewBuilder
    private var binding: some View {
        switch state.binding {
        case let .bound(title):
            Button(title, action: configure)
                .buttonStyle(DishOutlinedButtonStyle())
        case let .unbound(label, action):
            Text(label)
                .font(DishFont.mono)
                .foregroundColor(DishTheme.muted)
            Button(action, action: configure)
                .buttonStyle(DishOutlinedButtonStyle())
        }
    }

    private var pathActions: PadPathSection.Actions {
        PadPathSection.Actions(check: checkInput, pick: pickPath, helpSupport: helpSupport)
    }

    private func configure() {
        actions.configure(state.id)
    }

    private func checkInput() {
        actions.checkInput(state.id)
    }

    private func pickPath(_ source: InputSource) {
        actions.pickPath(source, state.id)
    }

    private func helpSupport() {
        actions.helpSupport(state.id)
    }

    private func openDeadZones() {
        actions.deadZones(state.id)
    }

    private func toggleMic() {
        guard let mic = state.mic else { return }
        actions.setMicMuted(mic.muteOnClick, state.id)
    }
}
