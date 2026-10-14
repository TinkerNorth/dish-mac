// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// From the wire conventions the sources already speak (the satellite's
// scales) onto the Moonlight control stream's, so both transports share
// every source: gyro int16 at ±2000 deg/s to deg/s, accel int16 at ±4 g to
// m/s², touch int16 to 0...1, the battery status byte to Wolf's states.

import Foundation

public enum MoonlightTelemetry {
    static let gyroScale: Float = 2000.0 / 32767.0
    static let accelScaleG: Float = 4.0 / 32767.0
    static let standardGravity: Float = 9.80665

    public static func gyroDegreesPerSecond(_ wire: Int16) -> Float {
        Float(wire) * gyroScale
    }

    public static func accelMetersPerSecondSquared(_ wire: Int16) -> Float {
        Float(wire) * accelScaleG * standardGravity
    }

    public static func touchNormalized(_ wire: Int16) -> Float {
        (Float(wire) + 32768) / 65535
    }

    /// The satellite's battery status onto Wolf's states, so one source feeds
    /// both transports. Wired (no battery, powered by the cable) is "nothing
    /// to show", as the satellite itself treats it.
    public static func batteryState(_ status: BatteryStatus) -> UInt8 {
        switch status {
        case .unknown: MoonlightBatteryState.unknown
        case .discharging: MoonlightBatteryState.discharging
        case .charging: MoonlightBatteryState.charging
        case .full: MoonlightBatteryState.full
        case .wired: MoonlightBatteryState.notPresent
        }
    }

    public static func batteryPercentage(_ level: Int) -> UInt8 {
        (0 ... 100).contains(level) ? UInt8(level) : MoonlightBatteryState.percentageUnknown
    }
}

/// What the host asked to receive (MOTION_EVENT): per pad and motion type a
/// report rate, 0 to stop. Senders keep their own cadence; `shouldSend`
/// applies the host's ceiling so a 100 Hz request never receives 200 Hz.
public struct MoonlightMotionGate: Equatable, Sendable {
    struct Stream: Equatable {
        let controller: UInt8
        let type: UInt8
        var rateHz: UInt16
        var lastSentNs: Int64?
    }

    private(set) var streams: [Stream] = []

    public init() {}

    public mutating func onMotionRequest(controller: UInt8, rateHz: UInt16, type: UInt8) {
        let index = streams.firstIndex { $0.controller == controller && $0.type == type }
        switch (index, rateHz) {
        case let (index?, 0):
            streams.remove(at: index)
        case let (index?, rate):
            streams[index].rateHz = rate
        case (nil, 0):
            break
        case let (nil, rate):
            streams.append(Stream(controller: controller, type: type, rateHz: rate, lastSentNs: nil))
        }
    }

    public mutating func clear(controller: UInt8) {
        streams.removeAll { $0.controller == controller }
    }

    public mutating func clearAll() {
        streams.removeAll()
    }

    public func wanted(controller: UInt8) -> Bool {
        streams.contains { $0.controller == controller }
    }

    public func wanted(controller: UInt8, type: UInt8) -> Bool {
        streams.contains { $0.controller == controller && $0.type == type }
    }

    /// True, and the send recorded, when a sample is due under the requested rate.
    public mutating func shouldSend(controller: UInt8, type: UInt8, nowNs: Int64) -> Bool {
        guard let index = streams.firstIndex(where: { $0.controller == controller && $0.type == type }) else { return false }
        let interval = 1_000_000_000 / Int64(streams[index].rateHz)
        if let last = streams[index].lastSentNs, nowNs - last < interval { return false }
        streams[index].lastSentNs = nowNs
        return true
    }
}

/// One touch event as the wire carries it.
public struct MoonlightTouchEmission: Equatable, Sendable {
    public var event: UInt8
    public var pointerId: UInt32
    public var x: Float
    public var y: Float
    public var pressure: Float
}

/// Turns full-state two-finger touch snapshots into the per-pointer DOWN,
/// MOVE and UP events the wire wants, keeping each finger's last contact. A
/// changed tracking id on an active finger is a lift plus a fresh contact.
public struct MoonlightTouchDiffer: Equatable, Sendable {
    public static let fingers = 2
    static let touching: Float = 1
    static let lifted: Float = 0

    struct Contact: Equatable {
        var active = false
        var id: UInt32 = 0
        var x: Float = 0
        var y: Float = 0
    }

    private(set) var contacts = [Contact](repeating: Contact(), count: MoonlightTouchDiffer.fingers)

    public init() {}

    public mutating func reset() {
        contacts = [Contact](repeating: Contact(), count: Self.fingers)
    }

    /// The events this finger's snapshot produces against its last, in wire order.
    public mutating func diff(finger: Int, active: Bool, id: UInt32, x: Float, y: Float) -> [MoonlightTouchEmission] {
        guard contacts.indices.contains(finger) else { return [] }
        let held = contacts[finger]
        defer { contacts[finger] = Contact(active: active, id: id, x: x, y: y) }
        let down = MoonlightTouchEmission(event: MoonlightTouchEvent.down, pointerId: id, x: x, y: y, pressure: Self.touching)
        let up = MoonlightTouchEmission(event: MoonlightTouchEvent.up, pointerId: held.id, x: held.x, y: held.y, pressure: Self.lifted)
        switch (held.active, active) {
        case (false, true): return [down]
        case (true, false): return [up]
        case (true, true) where held.id != id: return [up, down]
        case (true, true) where held.x != x || held.y != y:
            return [MoonlightTouchEmission(event: MoonlightTouchEvent.move, pointerId: id, x: x, y: y, pressure: Self.touching)]
        case (true, true), (false, false): return []
        }
    }
}

/// Two independent host streams, body rumble and trigger rumble, landing on
/// a pad with two body motors: per-motor maximum, never last-writer-wins and
/// never a sum, so neither cancels the other and nothing saturates. The left
/// trigger folds onto the strong motor and the right onto the weak one.
public struct MoonlightRumbleMix: Equatable, Sendable {
    public var bodyStrong: UInt16 = 0
    public var bodyWeak: UInt16 = 0
    public var triggerLeft: UInt16 = 0
    public var triggerRight: UInt16 = 0

    public init() {}

    public var mixed: (strong: UInt16, weak: UInt16) {
        (max(bodyStrong, triggerLeft), max(bodyWeak, triggerRight))
    }

    public func withBody(strong: UInt16, weak: UInt16) -> MoonlightRumbleMix {
        var mix = self
        mix.bodyStrong = strong
        mix.bodyWeak = weak
        return mix
    }

    public func withTriggers(left: UInt16, right: UInt16) -> MoonlightRumbleMix {
        var mix = self
        mix.triggerLeft = left
        mix.triggerRight = right
        return mix
    }
}
