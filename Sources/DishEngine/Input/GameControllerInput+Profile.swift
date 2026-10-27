// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import Foundation
import GameController

/// The d-pad's four buttons and the wire bits they are.
private let directionPadButtons: [(KeyPath<GCControllerDirectionPad, GCControllerButtonInput>, WireButton)] = [
    (\.up, .dpadUp),
    (\.down, .dpadDown),
    (\.left, .dpadLeft),
    (\.right, .dpadRight)
]

/// The pads GameController adopts without an extended profile (the Switch
/// Online N64 pad among them), read through `physicalInputProfile` with a
/// core `ProfileLayout`.
extension GameControllerInput {

    /// A pad's profile inputs, resolved once at attach so a report walks
    /// fixed arrays and builds nothing.
    struct ProfileInputs {
        /// The inputs read as held or not: buttons, full triggers, C buttons.
        let pressed: [(input: GCControllerButtonInput, role: ProfileButtonRole)]
        let triggers: [(input: GCControllerButtonInput, side: PadSide)]
        let dpads: [GCControllerDirectionPad]
        let sticks: [(input: GCControllerDirectionPad, side: PadSide)]
    }

    /// A pad that steers with nothing or presses nothing is logged and left
    /// alone; one that does gets a slot, the input queue and the handlers.
    /// The layout and what it left unclaimed are logged the first time the
    /// pad is seen.
    func attachByProfile(_ controller: GCController) {
        let profile = controller.physicalInputProfile
        let elements = Self.elementAliases(profile)
        let choice = chooseProfileLayout(
            productCategory: controller.productCategory,
            vendorName: controller.vendorName,
            elementNames: elements.flatMap(\.self)
        )
        let resolved = resolveProfile(ProfileLayout.of(choice.kind), elements: elements)
        let name = controller.vendorName ?? controller.productCategory
        guard resolved.isAdoptable else {
            Self.logProfile(subject: name, choice: choice, resolved: resolved, adopted: false)
            return
        }
        let id = slotId(for: controller)
        let gate = admit(controller, id: id)
        let firstSight = !slots.contains { $0.id == id }
        recordSlot(id: id, controller: controller, capabilities: Self.profileCapabilities(controller), family: Self.family(of: controller))
        if firstSight { Self.logProfile(subject: id, choice: choice, resolved: resolved, adopted: true) }
        controller.handlerQueue = inputQueue
        installProfileHandler(id: id, profile: profile, inputs: Self.profileInputs(resolved, profile: profile), gate: gate)
        installMotionHandler(id: id, controller: controller, gate: gate)
        startBatteryTimer(deviceId: id, controller: controller)
    }

    /// No touchpad, trigger effects or player LEDs reach a pad without the
    /// extended profile; the rest is the controller's own.
    static func profileCapabilities(_ controller: GCController) -> ControllerCapabilities {
        ControllerCapabilities(
            hasMotion: controller.motion != nil,
            hasTouchpad: false,
            hasRumble: controller.haptics != nil,
            hasLightbar: controller.light != nil,
            hasBattery: true,
            hasTriggerEffects: false,
            hasPlayerLeds: false
        )
    }

    /// One entry per element, holding every name the profile files it under.
    static func elementAliases(_ profile: GCPhysicalInputProfile) -> [[String]] {
        let byElement = Dictionary(grouping: profile.elements, by: { ObjectIdentifier($0.value) })
        return byElement.values.map { $0.map(\.key).sorted() }.sorted { $0.joined() < $1.joined() }
    }

    /// The DEVCAPS tail: every element name and the profile's counts.
    static func profileCensus(_ profile: GCPhysicalInputProfile) -> String {
        let names = profile.elements.keys.sorted().joined(separator: ", ")
        let counts = "allButtons=\(profile.allButtons.count) allAxes=\(profile.allAxes.count) allDpads=\(profile.allDpads.count)"
        return "elements=[\(names)] \(counts)"
    }

    /// What the layout bound, the rows the pad lacks and the elements no row
    /// claims, so a log from the pad finishes the table.
    static func logProfile(subject: String, choice: ProfileLayoutChoice, resolved: ResolvedProfile, adopted: Bool) {
        let bound = (resolved.buttons.map(\.name) + resolved.directions.map(\.name)).joined(separator: ", ")
        let line = """
        DEVCAPS PROFILE subject=\(subject) adopted=\(adopted ? "yes" : "no") layout=\(choice.kind) \
        matchedOn=\(choice.evidence.rawValue) bound=[\(bound)] missing=[\(resolved.missing.joined(separator: ", "))] \
        unclaimed=[\(resolved.unclaimed.joined(separator: ", "))]
        """
        log.info("\(line, privacy: .public)")
    }

    /// The bound rows as the profile's own inputs; a name the profile files
    /// under a different kind of element binds nothing.
    static func profileInputs(_ resolved: ResolvedProfile, profile: GCPhysicalInputProfile) -> ProfileInputs {
        let buttons = resolved.buttons.compactMap { binding in profile.buttons[binding.name].map { (input: $0, role: binding.role) } }
        let directions = resolved.directions.compactMap { binding in profile.dpads[binding.name].map { (input: $0, role: binding.role) } }
        return ProfileInputs(
            pressed: buttons.filter { $0.role.analogSide == nil },
            triggers: buttons.compactMap { button in button.role.analogSide.map { (input: button.input, side: $0) } },
            dpads: directions.filter { $0.role.stickSide == nil }.map(\.input),
            sticks: directions.compactMap { direction in direction.role.stickSide.map { (input: direction.input, side: $0) } }
        )
    }

    /// Any change re-reads the whole pad, as the extended path does.
    /// Nonisolated, so the compiler refuses a handler that reaches for
    /// main-actor state: it runs on the input queue.
    private nonisolated func installProfileHandler(id: String, profile: GCPhysicalInputProfile, inputs: ProfileInputs, gate: PadGate) {
        profile.valueDidChangeHandler = { [weak self] _, _ in
            self?.pushProfileReport(id: id, inputs: inputs, gate: gate)
        }
    }

    /// Every handler call is a change; the gate says whether it is published.
    nonisolated func pushProfileReport(id: String, inputs: ProfileInputs, gate: PadGate) {
        guard gate.pass(.standard, changed: true) else { return }
        let sample = Self.profileSample(inputs)
        processor.publish(deviceId: id, state: wireReport(from: sample))
    }

    /// The pad through its resolved inputs, in the framework's orientation,
    /// which is the wire's: up is positive.
    nonisolated static func profileSample(_ inputs: ProfileInputs) -> ProfileSample {
        var sample = ProfileSample()
        for (input, role) in inputs.pressed where input.isPressed {
            sample.press(role)
        }
        for (input, side) in inputs.triggers {
            sample.pull(side, input.value)
        }
        for dpad in inputs.dpads {
            pressDirectionPad(dpad, into: &sample)
        }
        for (input, side) in inputs.sticks {
            sample.steer(side, x: input.xAxis.value, y: input.yAxis.value)
        }
        return sample
    }

    private nonisolated static func pressDirectionPad(_ dpad: GCControllerDirectionPad, into sample: inout ProfileSample) {
        for (part, button) in directionPadButtons where dpad[keyPath: part].isPressed {
            sample.press(.button(button))
        }
    }
}
