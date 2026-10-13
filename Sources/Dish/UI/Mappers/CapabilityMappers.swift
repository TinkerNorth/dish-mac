// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import DishEngine
import Foundation
import SwiftUI

// MARK: - The solver's inputs

/// What the solver takes, from a bound slot's facts and the user's switches.
/// The link layer is this client: GameController carries everything the pad
/// exposes and routes no mouse; no controller audio route exists yet, so the
/// pad layer refuses the mic and the speaker.
func capabilityInputs(_ slot: ControllerSlot, _ flags: ForwardingFlags) -> CapabilityInputs {
    var inputs = CapabilityInputs()
    inputs.padMotion = slot.capabilities.hasMotion
    inputs.padTouchpad = slot.capabilities.hasTouchpad
    inputs.padRumble = slot.capabilities.hasRumble
    inputs.padLightbar = slot.capabilities.hasLightbar
    inputs.padTriggerEffects = slot.capabilities.hasTriggerEffects
    inputs.padPlayerLeds = slot.capabilities.hasPlayerLeds
    inputs.linkRoutesMouse = false
    applyTypeFacts(slot.typeFeatures, to: &inputs)
    applyHostFacts(slot.hostProbe, to: &inputs)
    inputs.userMotionOn = flags.motion
    inputs.userRumbleOn = flags.rumble
    inputs.userLightbarOn = flags.lightbar
    inputs.userTouchpadPick = flags.touchpad ? .pad : .off
    return inputs
}

private func applyTypeFacts(_ facts: TypeFeatureFacts?, to inputs: inout CapabilityInputs) {
    guard let facts else { return }
    inputs.typeResolved = true
    inputs.typeMotion = facts.motion
    inputs.typeTouchpad = facts.touchpad
    inputs.typeRumble = facts.rumble
    inputs.typeLightbar = facts.lightbar
    inputs.typeTriggerEffects = facts.triggerEffects
    inputs.typePlayerLeds = facts.playerLeds
    inputs.typeMic = facts.mic
    inputs.typeSpeaker = facts.speaker
}

private func applyHostFacts(_ facts: HostProbeFacts?, to inputs: inout CapabilityInputs) {
    guard let facts else { return }
    inputs.hostResolved = true
    inputs.hostMouseControl = facts.mouseControl
    inputs.hostRumble = facts.rumble
    inputs.hostMic = facts.mic
    inputs.hostSpeaker = facts.speaker
}

// MARK: - The table

/// One row of "What carries": the feature, the verdict word and why.
struct CapabilityRowModel: Equatable, Identifiable {
    let feature: CapFeature
    let label: String
    let verdict: CapVerdict
    let verdictText: String
    let help: String

    var id: CapFeature {
        feature
    }
}

func capabilityTable(_ slot: ControllerSlot, _ flags: ForwardingFlags, words: L10n = .app) -> [CapabilityRowModel] {
    let typeName = emulatedTypeName(slot.emulation, words: words)
    return solveCapabilities(capabilityInputs(slot, flags)).map { row in
        CapabilityRowModel(
            feature: row.feature,
            label: capabilityFeatureText(row.feature, words: words),
            verdict: row.verdict,
            verdictText: capabilityVerdictText(row.verdict, words: words),
            help: capabilityHelp(row, typeName: typeName, words: words)
        )
    }
}

func capabilityFeatureText(_ feature: CapFeature, words: L10n = .app) -> String {
    switch feature {
    case .gamepad: words.gamepad
    case .triggers: words.analogTriggers
    case .motion: words.motion
    case .touchpad: words.touchpad
    case .mouse: words.mouse
    case .rumble: words.rumble
    case .lightbar: words.lightBar
    case .triggerEffects: words.adaptiveTriggers
    case .playerLeds: words.playerLeds
    case .mic: words.microphone
    case .speaker: words.speaker
    }
}

func capabilityVerdictText(_ verdict: CapVerdict, words: L10n = .app) -> String {
    switch verdict {
    case .available: words.supported
    case .unavailable: words.notAvailable
    case .pending: words.pending
    case .off: words.off
    }
}

func capabilityVerdictColor(_ verdict: CapVerdict) -> Color {
    switch verdict {
    case .available: DishTheme.success
    case .unavailable: DishTheme.error
    case .pending: DishTheme.warning
    case .off: DishTheme.muted
    }
}

/// The reason behind a verdict, naming the first failing layer when there
/// is one, because that is the one whose fix the user can act on.
func capabilityHelp(_ row: CapabilityRow, typeName: String, words: L10n = .app) -> String {
    let feature = capabilityFeatureText(row.feature, words: words)
    switch row.verdict {
    case .available: return words.everyLayerCarries(typeName)
    case .off: return words.switchedOffInSettings
    case .pending: return words.waitingForTheHostsCatalog
    case .unavailable: return layerReason(row.failingLayer ?? .host, feature: feature, typeName: typeName, words: words)
    }
}

private func layerReason(_ layer: CapLayer, feature: String, typeName: String, words: L10n) -> String {
    switch layer {
    case .input: words.padLacks(feature)
    case .link: words.macDoesNotRoute(feature)
    case .type: words.typeLacks(typeName, feature)
    case .host: words.hostLacks(feature)
    }
}

// MARK: - The Emulate picker

/// One choice in the picker; nil is Auto, the family's own type.
struct EmulateOption: Equatable, Identifiable {
    let id: Int?
    let label: String
}

func emulateOptions(_ emulation: SlotEmulation, words: L10n = .app) -> [EmulateOption] {
    [EmulateOption(id: nil, label: words.auto)] + emulation.offered.map { EmulateOption(id: $0.id, label: $0.label) }
}

/// What the picker shows selected: the pick, or Auto.
func emulateSelection(_ emulation: SlotEmulation) -> Int? {
    emulation.isOverride ? emulation.type : nil
}

/// The resolved type's name, else its number for a type the catalog does
/// not name.
func emulatedTypeName(_ emulation: SlotEmulation?, words: L10n = .app) -> String {
    guard let emulation else { return words.waitingOnTheType }
    return emulation.current?.label ?? words.typeNumber(emulation.type)
}

/// The line under the picker: what Auto sends, or nothing while the user's
/// own pick speaks for itself. An empty catalog still waits on the type.
func emulateDetail(_ emulation: SlotEmulation, words: L10n = .app) -> String {
    if emulation.offered.isEmpty { return words.waitingOnTheType }
    if emulation.isOverride { return "" }
    return words.autoSends(emulatedTypeName(emulation, words: words))
}

// MARK: - The motion chip

/// The gyro chip's state for a slot: the pad, the switch, the binding and
/// the satellite's word, most blocking first.
func motionIndicator(_ slot: ControllerSlot, _ flags: ForwardingFlags) -> MotionIndicatorState {
    motionIndicatorFor(MotionIndicatorInputs(
        hasGyro: slot.capabilities.hasMotion,
        userEnabled: flags.motion,
        carriesOnConnection: slot.boundStatus?.live == .connected || slot.boundStatus?.live == .unstable,
        hostHasSinkForType: slot.motionStatus?.sinkSupportedForType ?? true,
        backendOk: slot.motionStatus?.backendOk ?? true
    ))
}

func motionIndicatorText(_ state: MotionIndicatorState, words: L10n = .app) -> String {
    switch state {
    case .unavailable: words.motionNoGyroscope
    case .userDisabled: words.motionTurnedOff
    case .notForwarded: words.motionNotSent
    case .noHostSink: words.motionHostCannotReceive
    case .backendBroken: words.motionServerCannotDeliver
    case .forwarding: words.motionStreaming
    }
}

/// The two states the satellite is to blame for warn; the rest read as the
/// chip's ordinary on and off.
func motionIndicatorWarns(_ state: MotionIndicatorState) -> Bool {
    switch state {
    case .noHostSink, .backendBroken: true
    case .unavailable, .userDisabled, .notForwarded, .forwarding: false
    }
}

// MARK: - The link tier

func linkTierText(_ kind: ConnectionKind, words: L10n = .app) -> String {
    switch linkTierFor(kind) {
    case .fastest: words.tierFastest
    case .fast: words.tierFast
    case .basic: words.tierBasic
    }
}

func linkTierHelp(_ kind: ConnectionKind, words: L10n = .app) -> String {
    switch linkTierFor(kind) {
    case .fastest: words.tierFastestHelp
    case .fast: words.tierFastHelp
    case .basic: words.tierBasicHelp
    }
}

/// The rank reads from the colour before the word does.
func linkTierColor(_ kind: ConnectionKind) -> Color {
    switch linkTierFor(kind) {
    case .fastest: DishTheme.success
    case .fast: DishTheme.muted
    case .basic: DishTheme.warning
    }
}
