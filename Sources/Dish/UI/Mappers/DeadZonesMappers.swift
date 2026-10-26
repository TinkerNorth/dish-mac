// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import DishEngine
import Foundation

/// Dead zones & motion for one pad: the stick and trigger flats as sliders
/// over the desktops' 0 to 30 % travel with their live readouts, the reset,
/// and the pad's own motion switch.
struct DeadzonePageState: Equatable {
    let content: DeadzoneContent
    let footnote: String
}

enum DeadzoneContent: Equatable {
    case missing(title: String, body: String)
    case pad(DeadzoneCardState)
}

struct DeadzoneCardState: Equatable {
    let slotId: String
    let name: String
    let gyro: CapabilityChipState
    let reset: String
    let resetHelp: String
    let stick: DeadzoneSliderState
    let trigger: DeadzoneSliderState
    let motion: DeadzoneMotionState
}

struct DeadzoneSliderState: Equatable {
    let label: String
    let percent: Int
    let readout: String
    let maxPercent: Int
}

/// The pad's own motion switch, or why there is none.
enum DeadzoneMotionState: Equatable {
    case toggle(title: String, detail: String, on: Bool)
    case unavailable(String)
}

func deadzonePageState(slotId: String, slots: [ControllerSlot], facts: ShellFacts, words: L10n = .app) -> DeadzonePageState {
    let slot = slots.first { $0.id == slotId }
    let content: DeadzoneContent = slot.map { .pad(deadzoneCard($0, zones: facts.deadzones[$0.id] ?? .defaults, words: words)) }
        ?? .missing(title: words.noControllersConnected, body: words.connectAControllerForDeadZones)
    return DeadzonePageState(content: content, footnote: words.overridesArePerDevice)
}

func deadzoneCard(_ slot: ControllerSlot, zones: DeadzoneSetting, words: L10n = .app) -> DeadzoneCardState {
    let hasGyro = slot.capabilities.hasMotion
    let gyroLook = CapabilityChipLook(ink: hasGyro ? DishTheme.primary : DishTheme.muted, on: hasGyro, absent: !hasGyro)
    return DeadzoneCardState(
        slotId: slot.id,
        name: slot.name,
        gyro: CapabilityChipState(id: "gyro", text: hasGyro ? words.gyro : words.noGyro, look: gyroLook, help: ""),
        reset: words.resetToDefaults,
        resetHelp: words.resetDeadZonesFor(slot.name),
        stick: deadzoneSlider(words.stickDeadZone, percent: zones.stickPercent, words: words),
        trigger: deadzoneSlider(words.triggerDeadZone, percent: zones.triggerPercent, words: words),
        motion: hasGyro
            ? .toggle(title: words.forwardMotion, detail: words.forwardMotionDetail, on: slot.preferences.motion)
            : .unavailable(words.motionForwardingUnavailable)
    )
}

private func deadzoneSlider(_ label: String, percent: Int, words: L10n) -> DeadzoneSliderState {
    DeadzoneSliderState(label: label, percent: percent, readout: words.percent(percent), maxPercent: DeadzoneSetting.maxPercent)
}
