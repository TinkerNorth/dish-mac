// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// "Check the buttons": the desktops' capture-to-assignment fold
// (`withAssignment`, `withInvert`, the capture gates of `JoystickMapping`)
// and the guided walk over it, one wire control at a time, as a pure
// reducer whose effects come back as data.

import Foundation

/// The desktops' capture kinds, by their stored integers.
public enum CaptureKind: Int, Equatable, Sendable {
    case axis = 0
    case button = 1
    case hat = 2
}

/// One raw change the pad made: a button newly held, the d-pad moved off
/// centre, or an axis moved far from where it rested.
public struct RawCapture: Equatable, Sendable {
    public let kind: CaptureKind
    public let index: Int
    /// The axis's travel from rest (HID's sign: up is negative); 0 otherwise.
    public let travel: Int

    public init(kind: CaptureKind, index: Int, travel: Int = 0) {
        self.kind = kind
        self.index = index
        self.travel = travel
    }
}

public enum RemapTarget: Equatable, Sendable {
    case button(RemapButton)
    case guide
    case leftStickX
    case leftStickY
    case rightStickX
    case rightStickY
    case leftTrigger
    case rightTrigger
}

public enum InvertTarget: Equatable, Sendable {
    case leftY
    case rightY
}

public enum RemapCapture {
    /// The desktops' deliberate-press gate, so resting jitter never assigns.
    public static let axisThreshold = 16000
}

public func captureAxisPasses(_ value: Int) -> Bool {
    abs(value) > RemapCapture.axisThreshold
}

/// A button only reports a capture on a real press.
public func captureButtonPasses() -> Bool {
    true
}

/// A release back to centre is not an assignment.
public func captureHatPasses(_ dpad: UInt16) -> Bool {
    dpad != 0
}

/// One capture folded into `base`, verbatim, as the desktops do: a trigger
/// takes its kind from the capture, a d-pad capture from the hat drops the
/// direction's button, and an explicit right stick or trigger ends the
/// desktops' adaptive guess.
public func withAssignment(_ base: JoystickRemap, _ target: RemapTarget, _ capture: RawCapture) -> JoystickRemap {
    var next = base
    switch target {
    case let .button(which): assignButton(&next, which, capture)
    case .guide: next.guide = capture.index
    case .leftStickX: next.leftStickX = capture.index
    case .leftStickY: next.leftStickY = capture.index
    case .rightStickX:
        next.rightStickX = capture.index
        next.useAdaptiveRightStick = false
    case .rightStickY:
        next.rightStickY = capture.index
        next.useAdaptiveRightStick = false
    case .leftTrigger:
        next.leftTrigger = triggerSource(capture)
        next.useAdaptiveTriggers = false
    case .rightTrigger:
        next.rightTrigger = triggerSource(capture)
        next.useAdaptiveTriggers = false
    }
    return next
}

public func withInvert(_ base: JoystickRemap, _ which: InvertTarget, _ on: Bool) -> JoystickRemap {
    var next = base
    switch which {
    case .leftY: next.invertLeftY = on
    case .rightY: next.invertRightY = on
    }
    return next
}

private func assignButton(_ remap: inout JoystickRemap, _ which: RemapButton, _ capture: RawCapture) {
    let fromHat = capture.kind == .hat && isDpad(which)
    guard fromHat else { return remap.setButton(which, capture.index) }
    remap.hatIndex = capture.index
    remap.setButton(which, RemapDefaults.unassigned)
}

private func triggerSource(_ capture: RawCapture) -> TriggerSource {
    TriggerSource(kind: capture.kind == .button ? .button : .axis, index: capture.index)
}

private let dpadButtons: Set<RemapButton> = [.dpadUp, .dpadDown, .dpadLeft, .dpadRight]

private func isDpad(_ which: RemapButton) -> Bool {
    dpadButtons.contains(which)
}

// MARK: - The walk

/// One stop of the walk: a control to press, or a stick to push up so its
/// Y direction is known.
public enum RemapStep: Equatable, Sendable {
    case assign(RemapTarget)
    case invert(InvertTarget)
}

/// The walk's order: the face buttons, the shoulders, Back Start Guide, the
/// stick clicks, the d-pad, the triggers, then each stick pushed up.
public let remapWalk: [RemapStep] = [
    .assign(.button(.faceA)), .assign(.button(.faceB)), .assign(.button(.faceX)), .assign(.button(.faceY)),
    .assign(.button(.leftShoulder)), .assign(.button(.rightShoulder)),
    .assign(.button(.back)), .assign(.button(.start)), .assign(.guide),
    .assign(.button(.leftThumb)), .assign(.button(.rightThumb)),
    .assign(.button(.dpadUp)), .assign(.button(.dpadDown)), .assign(.button(.dpadLeft)), .assign(.button(.dpadRight)),
    .assign(.leftTrigger), .assign(.rightTrigger),
    .invert(.leftY), .invert(.rightY)
]

public struct RemapAssignState: Equatable, Sendable {
    /// Where the walk stands; `remapWalk.count` once every step is done.
    public var stepIndex = 0
    public var remap: JoystickRemap
    /// The remap the walk resets to: the model's own order.
    public let defaults: JoystickRemap

    public init(remap: JoystickRemap, defaults: JoystickRemap) {
        self.remap = remap
        self.defaults = defaults
    }

    public var step: RemapStep? {
        stepIndex < remapWalk.count ? remapWalk[stepIndex] : nil
    }
}

public enum RemapAssignEvent: Equatable, Sendable {
    case captured(RawCapture)
    case skip
    /// Back to the model's own order, stored remap dropped, from the top.
    case reset
    /// From the top again, keeping what is stored.
    case restart
}

public enum RemapAssignEffect: Equatable, Sendable {
    case store(JoystickRemap)
    case clearStored
    /// Ask the pad for its next raw change.
    case listen
    case stopListening
}

public struct RemapAssignReduction: Equatable, Sendable {
    public let next: RemapAssignState
    public let effects: [RemapAssignEffect]
}

public func reduceRemapAssign(_ state: RemapAssignState, _ event: RemapAssignEvent) -> RemapAssignReduction {
    switch event {
    case let .captured(capture): captured(state, capture)
    case .skip: advanced(state, stored: [])
    case .reset: restarted(state, remap: state.defaults, effects: [.clearStored])
    case .restart: restarted(state, remap: state.remap, effects: [])
    }
}

/// A change that does not fit the step (a stick moved while a button is
/// asked for) is not an assignment: the walk listens on.
private func captured(_ state: RemapAssignState, _ capture: RawCapture) -> RemapAssignReduction {
    guard let step = state.step else { return RemapAssignReduction(next: state, effects: [.stopListening]) }
    guard let assigned = assign(state.remap, step, capture) else { return RemapAssignReduction(next: state, effects: [.listen]) }
    var next = state
    next.remap = assigned
    return advanced(next, stored: [.store(assigned)])
}

private func advanced(_ state: RemapAssignState, stored: [RemapAssignEffect]) -> RemapAssignReduction {
    var next = state
    next.stepIndex = min(state.stepIndex + 1, remapWalk.count)
    let listening: RemapAssignEffect = next.step == nil ? .stopListening : .listen
    return RemapAssignReduction(next: next, effects: stored + [listening])
}

private func restarted(_ state: RemapAssignState, remap: JoystickRemap, effects: [RemapAssignEffect]) -> RemapAssignReduction {
    var next = state
    next.remap = remap
    next.stepIndex = 0
    return RemapAssignReduction(next: next, effects: effects + [.listen])
}

/// The capture folded into the step, or nil when its kind cannot drive it.
func assign(_ remap: JoystickRemap, _ step: RemapStep, _ capture: RawCapture) -> JoystickRemap? {
    switch step {
    case let .assign(target):
        return fits(capture.kind, target) ? withAssignment(remap, target, capture) : nil
    case let .invert(which):
        let onTheStick = capture.kind == .axis && capture.index == stickYAxis(remap, which)
        guard onTheStick else { return nil }
        let upIsNegative = capture.travel < 0
        return withInvert(remap, which, upIsNegative)
    }
}

/// The axis the stick's Y reads, so a push that strays sideways is not taken.
private func stickYAxis(_ remap: JoystickRemap, _ which: InvertTarget) -> Int {
    switch which {
    case .leftY: remap.leftStickY
    case .rightY: remap.rightStickY
    }
}

private func fits(_ kind: CaptureKind, _ target: RemapTarget) -> Bool {
    switch target {
    case let .button(which): kind == .button || (kind == .hat && isDpad(which))
    case .guide: kind == .button
    case .leftStickX, .leftStickY, .rightStickX, .rightStickY: kind == .axis
    case .leftTrigger, .rightTrigger: kind == .button || kind == .axis
    }
}
