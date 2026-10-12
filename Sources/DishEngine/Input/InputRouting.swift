// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import Foundation

/// Thread-safe slot id to live connection table. Written on the main actor
/// when bindings or the pool change; read on the controller callback threads
/// once per event.
final class RoutingTable: @unchecked Sendable {
    private var map: [String: WifiConnection] = [:]
    private var lock = os_unfair_lock_s()

    func get(_ slotId: String) -> WifiConnection? {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return map[slotId]
    }

    func set(_ snapshot: [String: WifiConnection]) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        map = snapshot
    }
}

/// The hot path from the input processor to the wire: one locked table read
/// per event, no main-actor hop. The motion and touchpad streams also pass
/// the user's forwarding gate.
final class InputRouting: @unchecked Sendable {
    let table = RoutingTable()
    let gate: ForwardingGate

    init(gate: ForwardingGate) {
        self.gate = gate
    }

    /// Point the processor's senders at this router.
    func install(on processor: GamepadInputProcessor) {
        processor.reportSender = sendReport
        processor.motionSender = sendMotion
        processor.touchpadSender = sendTouchpad
        processor.batterySender = sendBattery
    }

    func sendReport(_ deviceId: String, _ report: GamepadReport) {
        guard let conn = table.get(deviceId) else { return }
        conn.sendReport(report)
    }

    func sendMotion(_ deviceId: String, _ sample: MotionSample, _ timestampDeltaUs: UInt32) {
        guard gate.snapshot().motion else { return }
        guard let conn = table.get(deviceId) else { return }
        conn.sendMotion(sample, timestampDeltaUs: timestampDeltaUs)
    }

    func sendTouchpad(_ deviceId: String, _ sample: TouchpadSample, _ eventTimeMs: UInt32) {
        guard gate.snapshot().touchpad else { return }
        guard let conn = table.get(deviceId) else { return }
        conn.sendTouchpad(sample: sample, eventTimeMs: eventTimeMs)
    }

    /// An unknown status byte from a future firmware reads as unknown.
    func sendBattery(_ deviceId: String, _ level: UInt8, _ statusRaw: UInt8) {
        guard let conn = table.get(deviceId) else { return }
        let status = BatteryStatus(rawValue: statusRaw) ?? .unknown
        conn.sendBattery(level: level, status: status)
    }
}
