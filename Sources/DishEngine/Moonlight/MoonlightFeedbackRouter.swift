// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import Foundation

/// How a host's feedback reaches a pad: the controller bridge in
/// production, recorders in tests.
struct MoonlightFeedbackActuators {
    var rumble: @MainActor (_ deviceId: String, _ strong: UInt16, _ weak: UInt16, _ durationMs: UInt16) -> Void
    var lightbar: @MainActor (_ deviceId: String, _ r: UInt8, _ g: UInt8, _ b: UInt8) -> Void

    @MainActor
    static func live(_ input: GameControllerInput) -> MoonlightFeedbackActuators {
        MoonlightFeedbackActuators(
            rumble: { deviceId, strong, weak, durationMs in
                input.applyRumble(deviceId: deviceId, strongMagnitude: strong, weakMagnitude: weak, durationMs: durationMs)
            },
            lightbar: { deviceId, r, g, b in input.applyLightbar(deviceId: deviceId, r: r, g: g, b: b) }
        )
    }
}

/// What a Moonlight host says back, landed on the pad bound to the number
/// it names; the sibling of ReturnPathRouter. Body rumble and trigger
/// rumble are two host streams onto one pad's two motors, folded per motor
/// (never last-writer-wins, never a sum) behind the controller's Rumble
/// switch; the lamp follows the Light bar setting. A Moonlight rumble has
/// no duration: it holds until the host sends the next, so each is
/// delivered for as long as the actuator allows and a session that drops
/// mid-buzz stops on its own. The gate runs on the transport's queue
/// against the routing table; the actuation hops to the main actor.
@MainActor
final class MoonlightFeedbackRouter {
    static let rumbleHoldMs: UInt16 = 1500

    private let actuators: MoonlightFeedbackActuators
    private let gate: ForwardingGate
    private let table: RoutingTable
    private let mixes = LockedBox<[String: MoonlightRumbleMix]>([:])
    /// Hosts already wired, pruned to the pool on every pool change so a
    /// forgotten host that comes back under the same id is wired again.
    private var wired: Set<String> = []

    init(actuators: MoonlightFeedbackActuators, gate: ForwardingGate, table: RoutingTable) {
        self.actuators = actuators
        self.gate = gate
        self.table = table
    }

    /// Wire every host in the pool once, and forget the ones that left.
    func wire(_ pool: [String: MoonlightConnection]) {
        wired.formIntersection(pool.keys)
        for (id, conn) in pool where !wired.contains(id) {
            wired.insert(id)
            let link = conn.link
            conn.setFeedbackHandler { [weak self] event in self?.arrived(event, link: link) }
        }
    }

    /// Transport queue: the slot the number names, the switch in force for it, then the hop.
    private nonisolated func arrived(_ event: MoonlightEvent, link: MoonlightPadLink) {
        switch event {
        case let .rumble(controller, low, high):
            rumble(link, controller: controller) { $0.withBody(strong: low, weak: high) }
        case let .rumbleTriggers(controller, left, right):
            rumble(link, controller: controller) { $0.withTriggers(left: left, right: right) }
        case let .rgbLed(controller, red, green, blue):
            let command = LightbarCommand(controllerIndex: UInt8(truncatingIfNeeded: controller), r: red, g: green, b: blue)
            guard let slotId = link.slot(forController: controller),
                  ReturnPathRouting.shouldApply(lightbar: command, flags: gate.snapshot()) else
            {
                return
            }
            Task { @MainActor in self.actuators.lightbar(slotId, red, green, blue) }
        case .motionRequest, .termination, .unknown:
            break
        }
    }

    /// Low frequency is the large motor, which the actuators call strong.
    private nonisolated func rumble(_ link: MoonlightPadLink, controller: UInt16, fold: (MoonlightRumbleMix) -> MoonlightRumbleMix) {
        guard let slotId = link.slot(forController: controller) else { return }
        let mixed = mixes.mutate { mixes in
            let next = fold(mixes[slotId] ?? MoonlightRumbleMix())
            mixes[slotId] = next
            return next.mixed
        }
        guard let route = table.get(slotId), ReturnPathRouting.shouldVibrate(flags: route.flags) else { return }
        Task { @MainActor in self.actuators.rumble(slotId, mixed.strong, mixed.weak, Self.rumbleHoldMs) }
    }
}
