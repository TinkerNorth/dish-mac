// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import Foundation

/// One pad's input on its way out. It is published on the one thread the
/// pad's source runs on (its GameController queue, the HID reader), which
/// owns the route, the motion gate and the touch ids; the main actor sets the
/// dead zones in an atomic word, hands the route over through a mailbox, and
/// reads what the pad last sent from the record under its seqlock. A report
/// takes no lock and builds nothing.
final class PadFeed {
    let deviceId: String
    let record = PadRecord()
    /// The pad's dead zones, packed: written by the main actor.
    private let deadzones = AtomicWord.allocate()
    private let routeMail = Mailbox<RouteBox>()
    private let lastInputMs: AtomicInt
    private let sent: AtomicCounter

    /// Owned by the publishing thread.
    private var route: Route?
    /// The last report `publishIfChanged` let through.
    private var latch: GamepadReport?
    private var lastMotionNs: UInt64?
    private var finger0 = FingerContact()
    private var finger1 = FingerContact()

    init(deviceId: String, lastInputMs: AtomicInt, sent: AtomicCounter) {
        self.deviceId = deviceId
        self.lastInputMs = lastInputMs
        self.sent = sent
    }

    deinit {
        deadzones.deallocate()
    }

    // MARK: - The main actor's side

    func useDeadzones(_ zones: GamepadInputProcessor.Deadzones) {
        deadzones.store(zones.packed)
    }

    /// The pad's route from now on; nil sends nothing.
    func post(route: Route?) {
        routeMail.post(RouteBox(route))
    }

    // MARK: - The publishing thread's side

    /// Filter a full-state report through the dead zones, record it, stamp
    /// the moment and send it.
    func publish(_ state: GamepadReport) {
        let filtered = applyDeadzones(state, GamepadInputProcessor.Deadzones(packed: deadzones.loadRelaxed()))
        record.write(raw: state, filtered: filtered)
        lastInputMs.set(Int(uptimeMs()))
        guard let route = currentRoute() else { return }
        sent.increment()
        route.sink.sendReport(filtered)
    }

    /// GameController calls a pad's handler for each element that moves, so
    /// one mapped report can come again and again: only a change from the
    /// last one let through is published, as the Direct lane publishes.
    func publishIfChanged(_ state: GamepadReport) {
        guard latch != state else { return }
        latch = state
        publish(state)
    }

    /// The pad's source stopped being published: its next report goes out
    /// whole, whatever it repeats.
    func forgetLatch() {
        latch = nil
    }

    /// Forward a wire-scaled sample, thinned to the rate limit, measured
    /// from the last emitted sample so a stream of drops never pushes the
    /// deadline forward.
    func publishMotion(_ sample: MotionSample, nowNs: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        guard let deltaUs = admitMotion(nowNs: nowNs) else { return }
        record.write(motion: sample)
        guard let route = currentRoute(), route.flags.motion else { return }
        route.sink.sendMotion(sample, timestampDeltaUs: deltaUs)
    }

    /// Forward a touchpad sample stamped with the publish instant (the
    /// framework surfaces no per-event timestamp), with the wheel's turn
    /// since the last sample, an event the POINTER frame carries.
    func publishTouchpad(_ sample: TouchpadSample, scrollV: Int16 = 0, nowNs: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        record.write(touch: sample)
        guard let route = currentRoute(), route.flags.touchpad else { return }
        route.sink.sendTouchpad(sample: sample, eventTimeMs: UInt32(truncatingIfNeeded: nowNs / 1_000_000), scrollV: scrollV)
    }

    /// An unknown status byte from a future firmware reads as unknown.
    func publishBattery(level: UInt8, statusRaw: UInt8) {
        guard let route = currentRoute() else { return }
        route.sink.sendBattery(level: level, status: BatteryStatus(rawValue: statusRaw) ?? .unknown)
    }

    /// Advance both fingers' ids for one sample and return the ids to stamp
    /// on the wire: each bumps on its finger's fresh contact.
    func advanceTouchIds(finger0Active: Bool, finger1Active: Bool) -> (finger0: UInt8, finger1: UInt8) {
        finger0.advance(active: finger0Active)
        finger1.advance(active: finger1Active)
        return (finger0.id, finger1.id)
    }

    private func currentRoute() -> Route? {
        if let fresh = routeMail.take() { route = fresh.route }
        return route
    }

    /// The delta to stamp on this sample, or nil when it falls inside the
    /// rate-limit window or the clock did not advance.
    private func admitMotion(nowNs: UInt64) -> UInt32? {
        guard let previous = lastMotionNs else {
            lastMotionNs = nowNs
            return 0
        }
        guard nowNs > previous else { return nil }
        let elapsedNs = nowNs - previous
        if elapsedNs < GamepadInputProcessor.motionMinIntervalNs { return nil }
        lastMotionNs = nowNs
        return UInt32(clamping: elapsedNs / 1000)
    }
}

/// One finger's last-seen contact and its current wire id.
private struct FingerContact {
    var wasActive = false
    var id: UInt8 = 0

    mutating func advance(active: Bool) {
        id = nextTouchpadTrackingId(wasActive: wasActive, isActive: active, current: id)
        wasActive = active
    }
}

/// One route as the mailbox carries it to the publishing thread.
final class RouteBox {
    let route: Route?

    init(_ route: Route?) {
        self.route = route
    }
}

/// What a pad last sent, as the main actor reads it.
struct LatestInput: Equatable {
    var raw: GamepadReport?
    var filtered: GamepadReport?
    var motion: MotionSample?
    var touch: TouchpadSample?
    var reports: UInt64 = 0
}

/// A pad's last report, motion sample and touch, written only by the
/// publishing thread and read by the main actor under a seqlock: the writer
/// makes the sequence odd, stores, and makes it even again; a reader keeps a
/// copy only when the sequence was even and unchanged across its loads. The
/// counts are words of their own.
final class PadRecord {
    private enum Slot: Int, CaseIterable {
        case sequence, rawLow, rawHigh, filteredLow, filteredHigh, motionLow, motionHigh, touchLow, touchHigh, present
        case reports, motion
    }

    private static let hasReport: Int64 = 1
    private static let hasMotion: Int64 = 2
    private static let hasTouch: Int64 = 4
    private static let readAttempts = 64

    private let words = UnsafeMutablePointer<Int64>.allocate(capacity: Slot.allCases.count)

    init() {
        words.initialize(repeating: 0, count: Slot.allCases.count)
    }

    deinit {
        words.deallocate()
    }

    private func word(_ slot: Slot) -> AtomicWord {
        AtomicWord(address: words + slot.rawValue)
    }

    var reportCount: UInt64 {
        UInt64(bitPattern: word(.reports).loadRelaxed())
    }

    var motionCount: UInt64 {
        UInt64(bitPattern: word(.motion).loadRelaxed())
    }

    func write(raw: GamepadReport, filtered: GamepadReport) {
        writing {
            word(.rawLow).storeRelaxed(raw.packedLow)
            word(.rawHigh).storeRelaxed(raw.packedHigh)
            word(.filteredLow).storeRelaxed(filtered.packedLow)
            word(.filteredHigh).storeRelaxed(filtered.packedHigh)
            word(.present).storeRelaxed(word(.present).loadRelaxed() | Self.hasReport)
        }
        word(.reports).storeRelaxed(word(.reports).loadRelaxed() &+ 1)
    }

    func write(motion: MotionSample) {
        writing {
            word(.motionLow).storeRelaxed(motion.packedLow)
            word(.motionHigh).storeRelaxed(motion.packedHigh)
            word(.present).storeRelaxed(word(.present).loadRelaxed() | Self.hasMotion)
        }
        word(.motion).storeRelaxed(word(.motion).loadRelaxed() &+ 1)
    }

    func write(touch: TouchpadSample) {
        writing {
            word(.touchLow).storeRelaxed(touch.packedLow)
            word(.touchHigh).storeRelaxed(touch.packedHigh)
            word(.present).storeRelaxed(word(.present).loadRelaxed() | Self.hasTouch)
        }
    }

    /// The writer's bracket: odd, the stores, even.
    private func writing(_ stores: () -> Void) {
        let sequence = word(.sequence).loadRelaxed()
        word(.sequence).storeRelaxed(sequence &+ 1)
        atomicFenceRelease()
        stores()
        word(.sequence).store(sequence &+ 2)
    }

    /// A consistent copy, or nil when a writer kept the record busy through
    /// every attempt.
    func read() -> LatestInput? {
        for _ in 0 ..< Self.readAttempts {
            let before = word(.sequence).load()
            if before & 1 == 0 {
                let copy = loadFields()
                atomicFenceAcquire()
                if word(.sequence).loadRelaxed() == before { return copy }
            }
            sched_yield()
        }
        return nil
    }

    private func loadFields() -> LatestInput {
        let present = word(.present).loadRelaxed()
        var input = LatestInput(reports: reportCount)
        if present & Self.hasReport != 0 {
            input.raw = GamepadReport(packedLow: word(.rawLow).loadRelaxed(), high: word(.rawHigh).loadRelaxed())
            input.filtered = GamepadReport(packedLow: word(.filteredLow).loadRelaxed(), high: word(.filteredHigh).loadRelaxed())
        }
        if present & Self.hasMotion != 0 {
            input.motion = MotionSample(packedLow: word(.motionLow).loadRelaxed(), high: word(.motionHigh).loadRelaxed())
        }
        if present & Self.hasTouch != 0 {
            input.touch = TouchpadSample(packedLow: word(.touchLow).loadRelaxed(), high: word(.touchHigh).loadRelaxed())
        }
        return input
    }
}

// MARK: - The record's packing: each value as two words, bit for bit

private func field(_ value: Int16, at shift: Int64) -> Int64 {
    Int64(UInt16(bitPattern: value)) << shift
}

private func int16(_ word: Int64, at shift: Int64) -> Int16 {
    Int16(bitPattern: UInt16(truncatingIfNeeded: word >> shift))
}

extension GamepadReport {
    var packedLow: Int64 {
        Int64(buttons) | Int64(lt) << 16 | Int64(rt) << 24 | field(lx, at: 32) | field(ly, at: 48)
    }

    var packedHigh: Int64 {
        field(rx, at: 0) | field(ry, at: 16) | Int64(extButtons) << 32
    }

    init(packedLow low: Int64, high: Int64) {
        self.init(
            buttons: UInt16(truncatingIfNeeded: low),
            lt: UInt8(truncatingIfNeeded: low >> 16),
            rt: UInt8(truncatingIfNeeded: low >> 24),
            lx: int16(low, at: 32),
            ly: int16(low, at: 48),
            rx: int16(high, at: 0),
            ry: int16(high, at: 16),
            extButtons: UInt32(truncatingIfNeeded: high >> 32)
        )
    }
}

extension MotionSample {
    var packedLow: Int64 {
        field(gyroX, at: 0) | field(gyroY, at: 16) | field(gyroZ, at: 32) | field(accelX, at: 48)
    }

    var packedHigh: Int64 {
        field(accelY, at: 0) | field(accelZ, at: 16)
    }

    init(packedLow low: Int64, high: Int64) {
        self.init(
            gyroX: int16(low, at: 0),
            gyroY: int16(low, at: 16),
            gyroZ: int16(low, at: 32),
            accelX: int16(low, at: 48),
            accelY: int16(high, at: 0),
            accelZ: int16(high, at: 16)
        )
    }
}

extension TouchpadSample {
    var packedLow: Int64 {
        field(finger0.x, at: 0) | field(finger0.y, at: 16) | field(finger1.x, at: 32) | field(finger1.y, at: 48)
    }

    var packedHigh: Int64 {
        (finger0.active ? 1 : 0) | Int64(finger0.id) << 1 | (finger1.active ? 1 << 9 : 0) | Int64(finger1.id) << 10
            | (buttonPressed ? 1 << 18 : 0) | (rightButtonPressed ? 1 << 19 : 0)
    }

    init(packedLow low: Int64, high: Int64) {
        self.init(
            finger0: TouchpadFinger(
                active: high & 1 != 0,
                id: UInt8(truncatingIfNeeded: high >> 1),
                x: int16(low, at: 0),
                y: int16(low, at: 16)
            ),
            finger1: TouchpadFinger(
                active: high & 1 << 9 != 0,
                id: UInt8(truncatingIfNeeded: high >> 10),
                x: int16(low, at: 32),
                y: int16(low, at: 48)
            ),
            buttonPressed: high & 1 << 18 != 0,
            rightButtonPressed: high & 1 << 19 != 0
        )
    }
}

extension GamepadInputProcessor.Deadzones {
    var packed: Int64 {
        field(stickFlat, at: 0) | Int64(triggerFlat) << 16
    }

    init(packed word: Int64) {
        self.init(stickFlat: int16(word, at: 0), triggerFlat: UInt8(truncatingIfNeeded: word >> 16))
    }
}
