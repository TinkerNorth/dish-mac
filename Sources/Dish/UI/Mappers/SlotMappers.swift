// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import DishEngine
import Foundation
import SwiftUI

/// The connections a slot may bind to: the one it is bound to, and every one
/// with room for another slot (a satellite and a Moonlight host carry four
/// pads each).
func bindableConnections(for slot: ControllerSlot, in connections: [ConnectionSummary]) -> [ConnectionSummary] {
    connections.filter { $0.boundSlotIds.contains(slot.id) || $0.hasRoomForAnotherSlot }
}

/// An unbound slot shows the muted dot.
func slotDotColor(_ slot: ControllerSlot) -> Color {
    guard let bound = slot.boundStatus else { return DishTheme.muted }
    return linkDotColor(bound.live)
}

/// GameController keeps the transport to itself, so a pad's link reads as
/// its family; a pad the framework does not name reads as the framework.
func padFamilyName(_ family: PadFamily) -> String {
    switch family {
    case .dualSense: "DualSense"
    case .dualShock4: "DualShock 4"
    case .xbox: "Xbox"
    case .nintendo: "Nintendo"
    case .other: "GameController"
    }
}

/// How a capability pill is drawn: the warning tone first, then on and off;
/// absent hardware is outlined dashed.
func capabilityChipLook(_ chip: CapabilityChipModel) -> CapabilityChipLook {
    let ink = chip.warning ? DishTheme.warning : (chip.on ? DishTheme.primary : DishTheme.muted)
    return CapabilityChipLook(ink: ink, on: chip.on, absent: !chip.available)
}

/// One capability pill. Three states a player can tell apart: available and
/// on, available but off in Settings, and absent from the hardware; a fourth
/// tone warns when the satellite, not the pad or the switch, is the reason.
/// A chip with a `switch` is the controller's own toggle for that feature,
/// clickable while the global switch in Settings is on.
struct CapabilityChipModel: Equatable {
    let label: String
    let on: Bool
    let available: Bool
    let help: String
    var warning = false
    var `switch`: SlotSwitch?
    var toggle = false
}

/// The chips for a slot as the card shows them: each present feature folds
/// the global switch with the controller's own and says which one is off;
/// bound, the gyro chip carries the satellite's word on motion, and the mic
/// chip warns while the system withholds its leave.
func capabilityChips(
    for slot: ControllerSlot,
    _ global: ForwardingFlags,
    micPermitted: Bool = true,
    words: L10n = .app
) -> [CapabilityChipModel] {
    let effective = effectiveFlags(global: global, slot: slot.preferences)
    let gyro = slot.capabilities.hasMotion
        ? switchChip(words.gyro, feature: words.motion, .motion, slot: slot, global: global, words: words)
        : CapabilityChipModel(label: words.noGyro, on: false, available: false, help: words.motionUnavailableHelp)
    let optional: [(present: Bool, label: String, feature: String, key: SlotSwitch)] = [
        (slot.capabilities.hasTouchpad, words.touchpad, words.touchpad, .touchpad),
        (slot.capabilities.hasRumble, words.rumble, words.rumble, .rumble),
        (slot.capabilities.hasMic, words.mic, words.microphone, .mic),
        (slot.capabilities.hasSpeaker, words.speaker, words.speaker, .speaker)
    ]
    let switches = optional.filter(\.present).map { entry in
        micPermissionWarning(
            switchChip(entry.label, feature: entry.feature, entry.key, slot: slot, global: global, words: words),
            micPermitted: micPermitted,
            words: words
        )
    }
    let lightbar = slot.capabilities.hasLightbar ? [detectedChip(
        words.lightbar,
        feature: words.lightBar,
        on: effective.lightbar,
        words: words
    )] : []
    return [boundGyro(gyro, slot: slot, effective: effective, words: words)] + switches + lightbar
}

/// A feature with a per-controller switch: off in Settings outranks off
/// here, and the hint says what a click does.
private func switchChip(
    _ label: String,
    feature: String,
    _ key: SlotSwitch,
    slot: ControllerSlot,
    global: ForwardingFlags,
    words: L10n
) -> CapabilityChipModel {
    let globalOn = globallyAllowed(key, global)
    let ownOn = switchValue(key, slot.preferences)
    guard globalOn else {
        return CapabilityChipModel(label: label, on: false, available: true, help: words.detectedOff(feature), switch: key, toggle: false)
    }
    let help = ownOn
        ? "\(switchedOnSentence(key, feature: feature, slot.preferences, words: words)) \(words.clickToTurnOffForThisController)"
        : "\(words.turnedOffForThisController) \(words.clickToTurnOnForThisController)"
    return CapabilityChipModel(label: label, on: ownOn, available: true, help: help, switch: key, toggle: true)
}

/// What a switched-on chip says of its feature: the detection line, where
/// the touchpad goes when it is the host's mouse, or for the pad's own
/// audio, where the sound goes.
private func switchedOnSentence(_ key: SlotSwitch, feature: String, _ preferences: SlotPreferences, words: L10n) -> String {
    switch key {
    case .motion, .rumble: words.detectedOn(feature)
    case .touchpad: preferences.touchpad == .mouse ? words.touchpadMovesTheMouse : words.detectedOn(feature)
    case .mic: words.micCarriesYourVoice
    case .speaker: words.hostAudioPlaysOnThePad
    }
}

/// One choice of the touchpad picker; the mouse is offered only by a host
/// that advertises mouse control.
struct TouchpadPickOption: Equatable, Identifiable {
    let id: TouchpadPick
    let label: String
    let enabled: Bool
}

func touchpadPickOptions(_ slot: ControllerSlot, words: L10n = .app) -> [TouchpadPickOption] {
    TouchpadPick.pickerOrder.map { pick in
        TouchpadPickOption(id: pick, label: touchpadPickText(pick, words: words), enabled: touchpadPickOffered(pick, slot))
    }
}

func touchpadPickText(_ pick: TouchpadPick, words: L10n = .app) -> String {
    switch pick {
    case .off: words.off
    case .pad: words.pad
    case .mouse: words.mouse
    }
}

/// Off and the pad render are always on offer; the mouse needs the host's
/// word, and an unprobed host has not spoken yet.
func touchpadPickOffered(_ pick: TouchpadPick, _ slot: ControllerSlot) -> Bool {
    switch pick {
    case .off, .pad: true
    case .mouse: slot.hostProbe?.mouseControl == true
    }
}

/// The pad's own audio has no global switch, so its chips answer to the
/// controller alone.
func globallyAllowed(_ key: SlotSwitch, _ global: ForwardingFlags) -> Bool {
    switch key {
    case .motion, .rumble, .touchpad: switchValue(key, global)
    case .mic, .speaker: true
    }
}

/// A mic switched on without the system's leave warns and says where to
/// turn it on; the click still works, so the switch can be turned off.
private func micPermissionWarning(_ chip: CapabilityChipModel, micPermitted: Bool, words: L10n) -> CapabilityChipModel {
    guard chip.switch == .mic, chip.on, !micPermitted else { return chip }
    return CapabilityChipModel(
        label: chip.label,
        on: true,
        available: true,
        help: words.micPermissionOff,
        warning: true,
        switch: .mic,
        toggle: true
    )
}

/// The microphone's standing on a bound controller: nil until it is armed,
/// then live or muted, and a click flips this controller's mute.
func micStatusChip(_ slot: ControllerSlot, words: L10n = .app) -> CapabilityChipModel? {
    guard let plan = slot.audio?.plan, plan.micArmed else { return nil }
    return plan.capture
        ? CapabilityChipModel(label: words.micLive, on: true, available: true, help: words.micLiveClickToMute)
        : CapabilityChipModel(label: words.micMuted, on: false, available: true, help: words.micMutedClickToUnmute)
}

/// The lamp the game asked for, while it asks: GameController reaches no
/// DualSense lamp, so the chip is the lamp.
func micLampChip(_ slot: ControllerSlot, words: L10n = .app) -> CapabilityChipModel? {
    switch slot.audio?.micLed {
    case .on: CapabilityChipModel(label: words.micLamp, on: true, available: true, help: "\(words.micLamp) · \(words.on)")
    case .pulse: CapabilityChipModel(label: words.micLamp, on: true, available: true, help: "\(words.micLamp) · \(words.pulse)")
    case .off, nil: nil
    }
}

/// Bound, the gyro chip reads the satellite's word; the click hint stays.
private func boundGyro(_ chip: CapabilityChipModel, slot: ControllerSlot, effective: ForwardingFlags, words: L10n) -> CapabilityChipModel {
    guard slot.boundConnectionId != nil, slot.capabilities.hasMotion else { return chip }
    let state = motionIndicator(slot, effective)
    let hint = chip.toggle ? " \(chip.on ? words.clickToTurnOffForThisController : words.clickToTurnOnForThisController)" : ""
    return CapabilityChipModel(
        label: chip.label,
        on: state == .forwarding,
        available: true,
        help: motionIndicatorText(state, words: words) + hint,
        warning: motionIndicatorWarns(state),
        switch: chip.switch,
        toggle: chip.toggle
    )
}

func switchValue(_ key: SlotSwitch, _ flags: ForwardingFlags) -> Bool {
    switch key {
    case .motion: flags.motion
    case .rumble: flags.rumble
    case .touchpad: flags.touchpad
    case .mic: flags.mic
    case .speaker: flags.speaker
    }
}

func switchValue(_ key: SlotSwitch, _ preferences: SlotPreferences) -> Bool {
    switch key {
    case .motion: preferences.motion
    case .rumble: preferences.rumble
    case .touchpad: preferences.touchpad != .off
    case .mic: preferences.mic
    case .speaker: preferences.speaker
    }
}

/// The chips for a slot. Motion always shows, present or explicitly absent;
/// touchpad, rumble and the light bar only when the pad has them.
func capabilityChips(_ caps: ControllerCapabilities, _ flags: ForwardingFlags, words: L10n = .app) -> [CapabilityChipModel] {
    let optional: [(present: Bool, label: String, feature: String, on: Bool)] = [
        (caps.hasTouchpad, words.touchpad, words.touchpad, flags.touchpad),
        (caps.hasRumble, words.rumble, words.rumble, flags.rumble),
        (caps.hasLightbar, words.lightbar, words.lightBar, flags.lightbar)
    ]
    return [motionChip(present: caps.hasMotion, on: flags.motion, words: words)]
        + optional.filter(\.present).map { detectedChip($0.label, feature: $0.feature, on: $0.on, words: words) }
}

private func motionChip(present: Bool, on: Bool, words: L10n) -> CapabilityChipModel {
    guard present else {
        return CapabilityChipModel(label: words.noGyro, on: false, available: false, help: words.motionUnavailableHelp)
    }
    return detectedChip(words.gyro, feature: words.motion, on: on, words: words)
}

private func detectedChip(_ label: String, feature: String, on: Bool, words: L10n) -> CapabilityChipModel {
    CapabilityChipModel(
        label: label,
        on: on,
        available: true,
        help: on ? words.detectedOn(feature) : words.detectedOff(feature)
    )
}
