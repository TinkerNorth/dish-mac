// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishEngine
import SwiftUI

/// Dead zones & motion for one pad, pushed from its Controllers card: the
/// stick and trigger flats as sliders with live readouts, applied to the
/// pad as they move and kept under the desktops' key, the reset to the
/// defaults, and the pad's own motion switch.
struct DeadZonesPage: View {

    @EnvironmentObject var model: AppModel
    let slotId: String

    private var state: DeadzonePageState {
        deadzonePageState(slotId: slotId, slots: model.slots, facts: model.shellFacts)
    }

    var body: some View {
        let state = state
        ScrollView {
            VStack(alignment: .leading, spacing: DishSpace.s6) {
                switch state.content {
                case let .missing(title, body):
                    EmptyStateCard(title: title, message: body)
                case let .pad(card):
                    DeadzoneCard(state: card, actions: actions)
                }
                Text(state.footnote)
                    .font(DishFont.caption)
                    .foregroundColor(DishTheme.muted)
            }
            .padding(DishSpace.page)
        }
    }

    private var actions: DeadzoneCard.Actions {
        DeadzoneCard.Actions(
            stick: setStick,
            trigger: setTrigger,
            reset: reset,
            motion: setMotion
        )
    }

    private func setStick(_ percent: Int) {
        model.setStickDeadzone(percent: percent, slotId: slotId)
    }

    private func setTrigger(_ percent: Int) {
        model.setTriggerDeadzone(percent: percent, slotId: slotId)
    }

    private func reset() {
        model.resetDeadzones(slotId: slotId)
    }

    private func setMotion(_ on: Bool) {
        model.setSlotSwitch(.motion, on: on, slotId: slotId)
    }
}

private struct DeadzoneCard: View {

    struct Actions {
        let stick: (Int) -> Void
        let trigger: (Int) -> Void
        let reset: () -> Void
        let motion: (Bool) -> Void
    }

    let state: DeadzoneCardState
    let actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: DishSpace.s6) {
            HStack(spacing: DishSpace.s5) {
                Text(state.name)
                    .font(DishFont.body)
                    .foregroundColor(DishTheme.onSurface)
                Spacer()
                CapabilityChip(text: state.gyro.text, look: state.gyro.look)
                Button(state.reset, action: actions.reset)
                    .buttonStyle(DishOutlinedButtonStyle())
                    .help(state.resetHelp)
                    .accessibilityLabel(state.resetHelp)
            }
            slider(state.stick, change: actions.stick)
            slider(state.trigger, change: actions.trigger)
            motion
        }
        .padding(DishSpace.s6)
        .background(DishTheme.surface)
        .overlay(RoundedRectangle(cornerRadius: DishSize.cardRadius).stroke(DishTheme.cardStroke, lineWidth: DishSize.hairline))
        .clipShape(RoundedRectangle(cornerRadius: DishSize.cardRadius))
    }

    private func slider(_ slider: DeadzoneSliderState, change: @escaping (Int) -> Void) -> some View {
        SliderRow(label: slider.label, readout: slider.readout, value: slider.percent, maxValue: slider.maxPercent, change: change)
    }

    @ViewBuilder
    private var motion: some View {
        switch state.motion {
        case let .toggle(title, detail, on):
            Toggle(isOn: Binding(get: { on }, set: actions.motion)) {
                VStack(alignment: .leading, spacing: DishSpace.s1) {
                    Text(title)
                        .font(DishFont.detail)
                        .foregroundColor(DishTheme.onSurface)
                    Text(detail)
                        .font(DishFont.caption)
                        .foregroundColor(DishTheme.muted)
                }
            }
            .toggleStyle(.switch)
        case let .unavailable(note):
            Text(note)
                .font(DishFont.caption)
                .foregroundColor(DishTheme.muted)
        }
    }
}
