// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import Foundation

/// Where a slot's input goes and which of its streams may flow: the live
/// connection and the switches in force for that controller, global and
/// per-controller folded together on the main actor.
struct Route {
    let connection: WifiConnection
    let flags: ForwardingFlags
}

/// A connection's side of the same table: the slot bound to it and the
/// switches in force for that controller, for the return paths.
struct BoundSlotRoute {
    let slotId: String
    let flags: ForwardingFlags
}

/// The two views of one binding table, rebuilt together so they can never
/// disagree.
struct RoutingSnapshot {
    var bySlot: [String: Route] = [:]
    var byConnection: [String: BoundSlotRoute] = [:]
}

/// Thread-safe routing table. Written on the main actor when bindings, the
/// pool or a switch change; read on the controller callback threads once per
/// event and on the receive queue once per return-path command.
final class RoutingTable: @unchecked Sendable {
    private var snapshot = RoutingSnapshot()
    private var lock = os_unfair_lock_s()

    func get(_ slotId: String) -> Route? {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return snapshot.bySlot[slotId]
    }

    func boundSlot(of connectionId: String) -> BoundSlotRoute? {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return snapshot.byConnection[connectionId]
    }

    func set(_ next: RoutingSnapshot) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        snapshot = next
    }
}

/// The hot path from the input processor to the wire: one locked table read
/// per event, no main-actor hop. The motion and touchpad streams also pass
/// the switches in force for the controller, already folded into its route.
final class InputRouting: @unchecked Sendable {
    let table = RoutingTable()

    /// Point the processor's senders at this router.
    func install(on processor: GamepadInputProcessor) {
        processor.reportSender = sendReport
        processor.motionSender = sendMotion
        processor.touchpadSender = sendTouchpad
        processor.batterySender = sendBattery
    }

    func sendReport(_ deviceId: String, _ report: GamepadReport) {
        guard let route = table.get(deviceId) else { return }
        route.connection.sendReport(report)
    }

    func sendMotion(_ deviceId: String, _ sample: MotionSample, _ timestampDeltaUs: UInt32) {
        guard let route = table.get(deviceId), route.flags.motion else { return }
        route.connection.sendMotion(sample, timestampDeltaUs: timestampDeltaUs)
    }

    func sendTouchpad(_ deviceId: String, _ sample: TouchpadSample, _ eventTimeMs: UInt32) {
        guard let route = table.get(deviceId), route.flags.touchpad else { return }
        route.connection.sendTouchpad(sample: sample, eventTimeMs: eventTimeMs)
    }

    /// An unknown status byte from a future firmware reads as unknown.
    func sendBattery(_ deviceId: String, _ level: UInt8, _ statusRaw: UInt8) {
        guard let route = table.get(deviceId) else { return }
        let status = BatteryStatus(rawValue: statusRaw) ?? .unknown
        route.connection.sendBattery(level: level, status: status)
    }
}
