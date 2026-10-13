// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// The one owner of the capability vocabulary behind the slot card's "What
// carries" table, the Swift form of the solver dish-android, dish-linux and
// dish-windows share:
//
//     available = input ∩ link ∩ type ∩ host
//
//   Input  what the pad itself reports
//   Link   the path. GameController carries everything the pad's profile
//          exposes, the adaptive triggers and player LEDs included; neither
//          path carries the mouse while this client does not route the
//          touchpad as one.
//   Type   the catalog type's features: an Xbox 360 type carries no gyro
//          however good the pad is
//   Host   the satellite's own inventory, from its capabilities probe
//
// Off means every layer carries it and the user switched it off, which is why
// it is distinct from Unavailable. Pending means the host or the catalog has
// not resolved; an unread layer never refuses, so a cross is never drawn from
// a guess. Tokens only; the words live in the app.

import Foundation

/// Declaration order is the render order every surface uses.
public enum CapFeature: UInt8, CaseIterable, Equatable, Sendable {
    case gamepad
    case triggers
    case motion
    case touchpad
    case mouse
    case rumble
    case lightbar
    case triggerEffects
    case playerLeds
    case mic
    case speaker
}

public enum CapLayer: Equatable, Sendable {
    case input
    case link
    case type
    case host
}

public enum CapVerdict: Equatable, Sendable {
    case available
    case unavailable
    case pending
    case off
}

/// How the user routes the touchpad: not at all, as the pad's own touchpad,
/// or as the host's mouse.
public enum TouchpadPick: Equatable, Sendable {
    case off
    case pad
    case mouse
}

public struct CapabilityInputs: Equatable, Sendable {
    // The pad. Rumble defaults true so an unknown slot does not refuse at the
    // input layer; the rarer actuators default false, since an unknown pad
    // claiming them would be the surprising answer.
    public var padMotion = false
    public var padTouchpad = false
    public var padRumble = true
    public var padLightbar = false
    public var padTriggerEffects = false
    public var padPlayerLeds = false
    public var padMic = false
    public var padSpeaker = false

    /// This client routes a touchpad as the host's mouse. Without it the link
    /// carries no mouse.
    public var linkRoutesMouse = false

    /// False means the type layer refuses nothing.
    public var typeResolved = false
    public var typeMotion = false
    public var typeTouchpad = false
    public var typeRumble = false
    public var typeLightbar = false
    public var typeTriggerEffects = false
    public var typePlayerLeds = false
    public var typeMic = false
    public var typeSpeaker = false

    /// False means Pending.
    public var hostResolved = false
    public var hostMouseControl = false
    public var hostRumble = false
    /// The probe's live verdict, conservative-false until it lands: audio is
    /// opt-in by design, so the honest answer before a probe is "not carried".
    public var hostMic = false
    public var hostSpeaker = false

    // The user's gates drive Off, never Unavailable. The audio defaults mirror
    // the fleet's stores: mic off until asked, speaker on.
    public var userMotionOn = true
    public var userRumbleOn = true
    public var userLightbarOn = true
    public var userMicOn = false
    public var userSpeakerOn = true
    public var userTouchpadPick = TouchpadPick.off

    public init() {}
}

public struct CapabilityRow: Equatable, Sendable {
    public let feature: CapFeature
    public let inputOk: Bool
    public let linkOk: Bool
    public let typeOk: Bool
    public let hostOk: Bool
    public let verdict: CapVerdict
    /// The first failing layer in input, link, type, host order, the one
    /// whose fix the user can act on; nil unless the verdict is unavailable.
    public let failingLayer: CapLayer?
}

/// A host waits on its catalog and its probe before any row can be judged.
public func capabilitiesPending(_ inputs: CapabilityInputs) -> Bool {
    !inputs.hostResolved || !inputs.typeResolved
}

public func solveCapabilities(_ inputs: CapabilityInputs) -> [CapabilityRow] {
    CapFeature.allCases.map { solveCapability($0, inputs) }
}

func solveCapability(_ feature: CapFeature, _ inputs: CapabilityInputs) -> CapabilityRow {
    let inputOk = inputCarries(inputs, feature)
    let linkOk = linkCarries(inputs, feature)
    let typeOk = typeCarries(inputs, feature)
    let hostOk = hostCarries(inputs, feature)
    let carried = inputOk && linkOk && typeOk && hostOk
    let verdict: CapVerdict = if capabilitiesPending(inputs) {
        .pending
    } else if carried {
        userEnabled(inputs, feature) ? .available : .off
    } else {
        .unavailable
    }
    return CapabilityRow(
        feature: feature,
        inputOk: inputOk,
        linkOk: linkOk,
        typeOk: typeOk,
        hostOk: hostOk,
        verdict: verdict,
        failingLayer: verdict == .unavailable ? firstFailingLayer(inputOk: inputOk, linkOk: linkOk, typeOk: typeOk) : nil
    )
}

/// Input before link before type; a row that reaches here with all three
/// carrying fails at the host.
func firstFailingLayer(inputOk: Bool, linkOk: Bool, typeOk: Bool) -> CapLayer {
    if !inputOk { return .input }
    if !linkOk { return .link }
    if !typeOk { return .type }
    return .host
}

/// Touchpad and mouse share one answer: the mouse is a routing of the
/// touchpad, so the pad needs one to drive it.
func inputCarries(_ inputs: CapabilityInputs, _ feature: CapFeature) -> Bool {
    switch feature {
    case .gamepad, .triggers: true
    case .motion: inputs.padMotion
    case .touchpad, .mouse: inputs.padTouchpad
    case .rumble: inputs.padRumble
    case .lightbar: inputs.padLightbar
    case .triggerEffects: inputs.padTriggerEffects
    case .playerLeds: inputs.padPlayerLeds
    case .mic: inputs.padMic
    case .speaker: inputs.padSpeaker
    }
}

/// GameController forwards everything the pad's profile exposes and reaches
/// the adaptive triggers and player LEDs through its own DualSense API, so
/// the mouse is the one thing the link carries conditionally.
func linkCarries(_ inputs: CapabilityInputs, _ feature: CapFeature) -> Bool {
    switch feature {
    case .mouse: inputs.linkRoutesMouse
    case .gamepad, .triggers, .motion, .touchpad, .rumble, .lightbar, .triggerEffects, .playerLeds, .mic, .speaker: true
    }
}

/// An unread catalog refuses nothing: a guessed "unsupported" is worse than
/// no table, and Pending is what says we do not know yet. The mouse is a
/// routing, not a catalog type feature.
func typeCarries(_ inputs: CapabilityInputs, _ feature: CapFeature) -> Bool {
    guard inputs.typeResolved else { return true }
    switch feature {
    case .gamepad, .triggers, .mouse: return true
    case .motion: return inputs.typeMotion
    case .touchpad: return inputs.typeTouchpad
    case .rumble: return inputs.typeRumble
    case .lightbar: return inputs.typeLightbar
    case .triggerEffects: return inputs.typeTriggerEffects
    case .playerLeds: return inputs.typePlayerLeds
    case .mic: return inputs.typeMic
    case .speaker: return inputs.typeSpeaker
    }
}

/// The same rule as the type layer for an unread host. Audio reads the
/// probe's live verdict, false until it lands.
func hostCarries(_ inputs: CapabilityInputs, _ feature: CapFeature) -> Bool {
    guard inputs.hostResolved else { return true }
    switch feature {
    case .gamepad, .triggers, .motion, .touchpad, .lightbar, .triggerEffects, .playerLeds: return true
    case .mouse: return inputs.hostMouseControl
    case .rumble: return inputs.hostRumble
    case .mic: return inputs.hostMic
    case .speaker: return inputs.hostSpeaker
    }
}

/// Only reached once all four layers carry the feature, so a user switch can
/// never masquerade as unsupported.
func userEnabled(_ inputs: CapabilityInputs, _ feature: CapFeature) -> Bool {
    switch feature {
    case .gamepad, .triggers, .triggerEffects, .playerLeds: true
    case .motion: inputs.userMotionOn
    case .rumble: inputs.userRumbleOn
    case .lightbar: inputs.userLightbarOn
    case .touchpad: inputs.userTouchpadPick == .pad
    case .mouse: inputs.userTouchpadPick == .mouse
    case .mic: inputs.userMicOn
    case .speaker: inputs.userSpeakerOn
    }
}
