// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// One Direct pad on the reader's thread. IOKit writes each input report into
// the lane's preallocated buffer and calls `hidPadReportCallback`, which
// decodes it in place: no Data, Array or String is built per report, and a
// report only reaches the processor when it changed something while the
// pad's source is Direct.

import DishCore
import Foundation
import IOKit.hid
import os

/// One decoded report, whatever the decoder: the XUSB state, and the motion
/// and battery when the pad's reports carry them.
struct LaneReading: Equatable {
    let report: GamepadReport
    let motion: MotionSample?
    let battery: PadBattery?
}

/// The lane's raw counts, which the main actor reads on its own ticks.
struct LaneTallySnapshot: Equatable {
    /// Every report IOKit delivered, decoded or not.
    let reports: UInt64
    /// From the lane's opening to its first report; nil before one arrives.
    let firstReportMs: Int64?
    /// The reports in the first second after the opening.
    let reportsFirstSecond: UInt64
}

/// The lane's counters, written on the reader's thread and read on main.
final class LaneTally: @unchecked Sendable {
    static let firstWindowNs: UInt64 = 1_000_000_000
    private static let nsPerMs: UInt64 = 1_000_000

    private let openedNs: UInt64
    private var reports: UInt64 = 0
    private var firstReportNs: UInt64?
    private var reportsFirstSecond: UInt64 = 0
    private var lock = os_unfair_lock_s()

    init(openedNs: UInt64) {
        self.openedNs = openedNs
    }

    func count(nowNs: UInt64) {
        os_unfair_lock_lock(&lock)
        reports &+= 1
        if firstReportNs == nil { firstReportNs = nowNs }
        let inFirstSecond = nowNs &- openedNs < Self.firstWindowNs
        if inFirstSecond { reportsFirstSecond &+= 1 }
        os_unfair_lock_unlock(&lock)
    }

    func snapshot() -> LaneTallySnapshot {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        let firstMs = firstReportNs.map { Int64(($0 &- openedNs) / Self.nsPerMs) }
        return LaneTallySnapshot(reports: reports, firstReportMs: firstMs, reportsFirstSecond: reportsFirstSecond)
    }
}

/// What a lane reaches beyond itself: the processor, and the main actor for
/// a battery change.
struct HidPadWiring {
    let processor: GamepadInputProcessor
    /// The gate's "tell me" post, which hops to the main actor itself.
    let notify: PadGate.Notify
    /// A battery change, posted to the main actor for the slot card.
    let battery: @Sendable (_ slotId: String, _ battery: PadBattery) -> Void
}

final class HidPadLane: @unchecked Sendable {
    let slotId: String
    let candidate: HidPadCandidate
    let gate: PadGate
    let tally: LaneTally
    /// IOKit writes each report here; owned by the lane for its whole life.
    let buffer: UnsafeMutablePointer<UInt8>
    let capacity: Int
    private let wiring: HidPadWiring
    /// The last battery seen, for the 30 s heartbeat on the main actor.
    private let batteryBox = LockedBox<PadBattery?>(nil)

    // Touched only on the reader's thread.
    private var calibration = SwitchStickCalibration()
    private var lastSeen: GamepadReport?
    private var lastPublished: GamepadReport?
    private var lastBattery: PadBattery?

    init(slotId: String, candidate: HidPadCandidate, wiring: HidPadWiring, openedNs: UInt64) {
        self.slotId = slotId
        self.candidate = candidate
        self.wiring = wiring
        gate = PadGate(key: slotId, notify: wiring.notify)
        tally = LaneTally(openedNs: openedNs)
        capacity = candidate.reportCapacity
        buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        buffer.initialize(repeating: 0, count: capacity)
    }

    deinit {
        buffer.deallocate()
    }

    /// The battery the pad last reported while Direct.
    var latestBattery: PadBattery? {
        batteryBox.get()
    }

    /// One report off the wire, on the reader's thread.
    func receive(_ report: UnsafeBufferPointer<UInt8>, nowNs: UInt64) {
        tally.count(nowNs: nowNs)
        guard let reading = decode(report) else { return }
        deliver(reading)
    }

    private func decode(_ report: UnsafeBufferPointer<UInt8>) -> LaneReading? {
        switch candidate.decoder {
        case let .switchReport(kind):
            guard let reading = decodeSwitchReport(report, kind: kind, calibration: &calibration) else { return nil }
            return LaneReading(report: reading.report, motion: reading.motion, battery: reading.battery)
        case let .hidGamepad(layout):
            guard let state = layout.decode(report) else { return nil }
            return LaneReading(report: state, motion: nil, battery: nil)
        }
    }

    /// The first report is the baseline, never a change. A lane that is not
    /// forwarded forgets what it published, so its first report once
    /// forwarded goes out whole.
    private func deliver(_ reading: LaneReading) {
        let changed = lastSeen.map { $0 != reading.report } ?? false
        lastSeen = reading.report
        let forwards = gate.pass(.direct, changed: changed)
        guard forwards else {
            lastPublished = nil
            lastBattery = nil
            return
        }
        publishIfChanged(reading.report)
        if let motion = reading.motion { wiring.processor.publishMotion(deviceId: slotId, sample: motion) }
        if let battery = reading.battery { publishBatteryIfChanged(battery) }
    }

    private func publishIfChanged(_ report: GamepadReport) {
        guard lastPublished != report else { return }
        lastPublished = report
        wiring.processor.publish(deviceId: slotId, state: report)
    }

    private func publishBatteryIfChanged(_ battery: PadBattery) {
        guard lastBattery != battery else { return }
        lastBattery = battery
        batteryBox.set(battery)
        wiring.processor.publishBattery(deviceId: slotId, level: battery.level, statusRaw: battery.status.rawValue)
        wiring.battery(slotId, battery)
    }
}

/// IOKit's input-report callback, on the reader's run loop: `context` is the
/// lane, retained for as long as the callback is registered.
func hidPadReportCallback(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    type: IOHIDReportType,
    reportId: UInt32,
    report: UnsafeMutablePointer<UInt8>,
    length: CFIndex
) {
    guard let context else { return }
    let lane = Unmanaged<HidPadLane>.fromOpaque(context).takeUnretainedValue()
    let bytes = UnsafeBufferPointer(start: report, count: min(Int(length), lane.capacity))
    lane.receive(bytes, nowNs: DispatchTime.now().uptimeNanoseconds)
}
