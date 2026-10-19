// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// The pads one Moonlight session carries, as one value: each slot's
// controller number and what the host was told it is, and per pad the
// host-side state the hot path reads. A touchpad click has no packet of its
// own (it is a button in the pad frame), so a click edge replays the pad's
// last frame with the bit merged; the host asks for motion per pad and
// type; touches are diffed per pad into per-pointer events. Pure, so every
// rule is pinned without a thread or a socket; the engine holds one under a
// lock and sends what it hands back.

import Foundation

public struct MoonlightPadTable: Equatable, Sendable {
    /// One pad as the session carries it.
    public struct Pad: Equatable, Sendable {
        public let slotId: String
        public let number: UInt8
        public var announced: MoonlightAnnouncedPad

        public init(slotId: String, number: UInt8, announced: MoonlightAnnouncedPad) {
            self.slotId = slotId
            self.number = number
            self.announced = announced
        }

        /// The arrival the host is sent for this pad.
        public var arrival: MoonlightInput.PadArrival {
            MoonlightInput.PadArrival(
                controller: number,
                type: announced.type,
                capabilities: announced.capabilities,
                supportedButtons: announced.supportedButtons
            )
        }
    }

    /// A pad's touchpad click as its last touch report said it; unknown
    /// until one has, so the first report is heard whichever way it says.
    public enum Click: Equatable, Sendable {
        case unknown
        case up
        case down
    }

    /// What one touch report puts on the wire: the pad's last frame again
    /// with the click merged on a click edge, then each finger's events.
    public struct TouchOut: Equatable, Sendable {
        public var controller: UInt8
        public var replay: MoonlightInput.PadFrame?
        public var emissions: [MoonlightTouchEmission]
    }

    /// One motion packet in the wire's units.
    public struct MotionOut: Equatable, Sendable {
        public var controller: UInt8
        public var type: UInt8
        public var x: Float
        public var y: Float
        public var z: Float
    }

    public struct BatteryOut: Equatable, Sendable {
        public var controller: UInt8
        public var state: UInt8
        public var percentage: UInt8
    }

    private var slots = MoonlightPadSlots()
    private var announced: [String: MoonlightAnnouncedPad] = [:]
    private var lastReports = [GamepadReport?](repeating: nil, count: MoonlightProtocol.maxPads)
    private var clicks = [Click](repeating: .unknown, count: MoonlightProtocol.maxPads)
    private var differs: [String: MoonlightTouchDiffer] = [:]
    private var motionGate = MoonlightMotionGate()

    public init() {}

    // MARK: - The table

    /// Every pad, in number order.
    public var pads: [Pad] {
        slots.assignments
            .compactMap { assignment in
                announced[assignment.slotId].map { Pad(slotId: assignment.slotId, number: assignment.number, announced: $0) }
            }
            .sorted { $0.number < $1.number }
    }

    public func pad(for slotId: String) -> Pad? {
        guard let number = slots.number(for: slotId), let wanted = announced[slotId] else { return nil }
        return Pad(slotId: slotId, number: number, announced: wanted)
    }

    /// The slot behind a number: how the host's feedback finds its pad.
    public func slot(for number: UInt8) -> String? {
        slots.slot(for: number)
    }

    public var activeMask: UInt16 {
        slots.activeMask
    }

    public var count: Int {
        slots.count
    }

    public var isEmpty: Bool {
        slots.isEmpty
    }

    public var isFull: Bool {
        slots.isFull
    }

    /// The lowest free number for a new slot, as the pad it asked for; the
    /// pad a slot already holds, unchanged (the host skips an arrival for a
    /// number it has seen, so a live number is never handed out twice); nil
    /// when the session carries its four.
    public mutating func acquire(_ slotId: String, as wanted: MoonlightAnnouncedPad) -> Pad? {
        if let held = pad(for: slotId) { return held }
        guard let number = slots.assign(slotId) else { return nil }
        announced[slotId] = wanted
        return Pad(slotId: slotId, number: number, announced: wanted)
    }

    /// The number the slot held, now free with its host-side state
    /// forgotten; nil when it held none.
    public mutating func release(_ slotId: String) -> UInt8? {
        guard let number = slots.release(slotId) else { return nil }
        announced.removeValue(forKey: slotId)
        forgetHostState(slotId: slotId, number: number)
        return number
    }

    /// The slot's pad as another pad under the same number, the host-side
    /// state of the old one forgotten: the new pad has asked for nothing
    /// yet. Nil when the slot holds none.
    public mutating func reannounce(_ slotId: String, as wanted: MoonlightAnnouncedPad) -> Pad? {
        guard let number = slots.number(for: slotId) else { return nil }
        announced[slotId] = wanted
        forgetHostState(slotId: slotId, number: number)
        return Pad(slotId: slotId, number: number, announced: wanted)
    }

    /// A session that goes down: what the host asked of or was told about
    /// every pad is forgotten; the pads stay claimed by their bindings.
    public mutating func forgetHostState() {
        for assignment in slots.assignments {
            forgetHostState(slotId: assignment.slotId, number: assignment.number)
        }
    }

    private mutating func forgetHostState(slotId: String, number: UInt8) {
        motionGate.clear(controller: number)
        differs.removeValue(forKey: slotId)
        lastReports[Int(number)] = nil
        clicks[Int(number)] = .unknown
    }

    // MARK: - The hot path

    /// XUSB's low sixteen less the mic-mute bit, and the touchpad click
    /// while it is held; nothing else is a button this client vouches for.
    public static func buttons(_ report: GamepadReport, clickHeld: Bool) -> UInt32 {
        let click = clickHeld ? MoonlightButton.touchpad : 0
        return (UInt32(report.buttons) | click) & MoonlightPadRules.frameButtonMask
    }

    /// HOT PATH: the frame this pad's report becomes, remembered for a
    /// click's replay; nil when the slot holds no pad.
    public mutating func frame(_ slotId: String, report: GamepadReport) -> MoonlightInput.PadFrame? {
        guard let number = slots.number(for: slotId) else { return nil }
        lastReports[Int(number)] = report
        return frame(number: number, report: report)
    }

    private func frame(number: UInt8, report: GamepadReport) -> MoonlightInput.PadFrame {
        MoonlightInput.PadFrame(
            controller: number,
            activeMask: slots.activeMask,
            buttons: Self.buttons(report, clickHeld: clicks[Int(number)] == .down),
            leftTrigger: report.lt,
            rightTrigger: report.rt,
            leftX: report.lx,
            leftY: report.ly,
            rightX: report.rx,
            rightY: report.ry
        )
    }

    /// HOT PATH: a click edge replays the pad's last frame (at rest before it
    /// has sent one) with the click merged, then each finger's events, first
    /// finger first; nil when the slot holds no pad. The click rides no touch
    /// event: BTN_TOUCHPAD travels in the pad frame.
    public mutating func touch(_ slotId: String, sample: TouchpadSample) -> TouchOut? {
        guard let number = slots.number(for: slotId) else { return nil }
        let click: Click = sample.buttonPressed ? .down : .up
        let edge = clicks[Int(number)] != click
        clicks[Int(number)] = click
        let replay = edge ? frame(number: number, report: lastReports[Int(number)] ?? .released) : nil
        var differ = differs[slotId] ?? MoonlightTouchDiffer()
        let first = Self.diff(&differ, finger: 0, sample.finger0)
        let second = Self.diff(&differ, finger: 1, sample.finger1)
        differs[slotId] = differ
        return TouchOut(controller: number, replay: replay, emissions: first + second)
    }

    private static func diff(_ differ: inout MoonlightTouchDiffer, finger: Int, _ contact: TouchpadFinger) -> [MoonlightTouchEmission] {
        differ.diff(
            finger: finger,
            active: contact.active,
            id: UInt32(contact.id),
            x: MoonlightTelemetry.touchNormalized(contact.x),
            y: MoonlightTelemetry.touchNormalized(contact.y)
        )
    }

    /// HOT PATH: the motion packets the host asked for, each under its own
    /// rate, in the wire's units; none while it asked for none.
    public mutating func motion(_ slotId: String, sample: MotionSample, nowNs: Int64) -> [MotionOut] {
        guard let number = slots.number(for: slotId) else { return [] }
        var out: [MotionOut] = []
        if motionGate.shouldSend(controller: number, type: MoonlightMotionType.gyro, nowNs: nowNs) {
            out.append(MotionOut(
                controller: number,
                type: MoonlightMotionType.gyro,
                x: MoonlightTelemetry.gyroDegreesPerSecond(sample.gyroX),
                y: MoonlightTelemetry.gyroDegreesPerSecond(sample.gyroY),
                z: MoonlightTelemetry.gyroDegreesPerSecond(sample.gyroZ)
            ))
        }
        if motionGate.shouldSend(controller: number, type: MoonlightMotionType.accelerometer, nowNs: nowNs) {
            out.append(MotionOut(
                controller: number,
                type: MoonlightMotionType.accelerometer,
                x: MoonlightTelemetry.accelMetersPerSecondSquared(sample.accelX),
                y: MoonlightTelemetry.accelMetersPerSecondSquared(sample.accelY),
                z: MoonlightTelemetry.accelMetersPerSecondSquared(sample.accelZ)
            ))
        }
        return out
    }

    /// The pad's battery in the host's vocabulary; nil when the slot holds no pad.
    public func battery(_ slotId: String, level: UInt8, status: BatteryStatus) -> BatteryOut? {
        guard let number = slots.number(for: slotId) else { return nil }
        return BatteryOut(
            controller: number,
            state: MoonlightTelemetry.batteryState(status),
            percentage: MoonlightTelemetry.batteryPercentage(Int(level))
        )
    }

    /// MOTION_EVENT from the host: start, re-rate or stop one motion stream of one pad.
    public mutating func onMotionRequest(controller: UInt8, rateHz: UInt16, type: UInt8) {
        motionGate.onMotionRequest(controller: controller, rateHz: rateHz, type: type)
    }

    public func motionWanted(_ slotId: String) -> Bool {
        guard let number = slots.number(for: slotId) else { return false }
        return motionGate.wanted(controller: number)
    }
}
