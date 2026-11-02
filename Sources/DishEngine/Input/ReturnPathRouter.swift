// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import Foundation

/// One connection's feedback routes, fixed when they are built: the record
/// and the switches in force for each controller index, and the global
/// light-bar switch. Its handlers run on the receive loop that opened each
/// command and only read it, so two loops may share one.
struct FeedbackRoutes {
    struct Route {
        let pad: FeedbackPad
        let flags: ForwardingFlags
    }

    let byIndex: [Route?]
    let global: ForwardingFlags

    /// The routes `snapshot` gives the connection's indices.
    @MainActor
    init(connectionId: String, snapshot: RoutingSnapshot, global: ForwardingFlags, feedback: PadFeedback) {
        var byIndex = [Route?](repeating: nil, count: SatelliteSlots.maxPerSatellite)
        for (pad, bound) in snapshot.bySatellitePad
            where pad.connectionId == connectionId && byIndex.indices.contains(pad.controllerIndex)
        {
            byIndex[pad.controllerIndex] = Route(pad: feedback.pad(for: bound.slotId), flags: bound.flags)
        }
        self.byIndex = byIndex
        self.global = global
    }

    /// The pad bound to the index, or nil for an index no pad holds.
    func route(_ controllerIndex: UInt8) -> Route? {
        let index = Int(controllerIndex)
        return byIndex.indices.contains(index) ? byIndex[index] : nil
    }

    /// Rumble is the bound controller's own switch.
    func rumble(_ command: RumbleCommand) {
        guard let route = route(command.controllerIndex), ReturnPathRouting.shouldVibrate(flags: route.flags) else { return }
        route.pad.post(rumble: command)
    }

    /// The light bar is the global switch.
    func lightbar(_ command: LightbarCommand) {
        guard ReturnPathRouting.shouldApply(lightbar: command, flags: global), let route = route(command.controllerIndex) else { return }
        route.pad.post(lightbar: command)
    }

    /// The two feedback paths have no switch: a pad only receives them when
    /// its descriptor claimed them.
    func triggerEffects(_ command: TriggerEffectsCommand) {
        route(command.controllerIndex)?.pad.post(triggerEffects: command)
    }

    func playerLeds(_ command: PlayerLedsCommand) {
        route(command.controllerIndex)?.pad.post(player: command.playerNumber)
    }
}

/// Routes the satellite's return paths (rumble, light bar, trigger effects,
/// player LEDs) from a connection to the controller bound to the index each
/// command names, so a satellite carrying four pads rumbles the right one.
/// Every routing change hands each connection handlers that capture fresh
/// `FeedbackRoutes`; the receive loop resolves and gates each command
/// against them and posts it to the pad's record, and the feedback queue
/// actuates it: one hop, no lock, no main actor.
@MainActor
final class ReturnPathRouter {
    private let feedback: PadFeedback
    private var pool: [String: WifiConnection] = [:]
    private var snapshot = RoutingSnapshot()
    private var global = ForwardingFlags()

    init(feedback: PadFeedback) {
        self.feedback = feedback
    }

    /// The pool changed: the connections it holds get the current routes.
    func wire(_ pool: [String: WifiConnection]) {
        self.pool = pool
        install()
    }

    /// The bindings or a switch changed.
    func route(_ snapshot: RoutingSnapshot, global: ForwardingFlags) {
        self.snapshot = snapshot
        self.global = global
        install()
    }

    private func install() {
        for (id, conn) in pool {
            conn.setFeedbackRoutes(FeedbackRoutes(connectionId: id, snapshot: snapshot, global: global, feedback: feedback))
        }
    }
}
