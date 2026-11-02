// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import Foundation

/// Turns raw controller values into the wire's report and hands each pad's
/// input to its `PadFeed`, which applies the dead zones, records it and sends
/// it on the publishing thread. The processor itself is the cold side: it
/// makes a pad's feed when the pad attaches, keeps the dead zones and the
/// routes the main actor resolved, and reads the records for the inspector
/// and the telemetry. No framework imports and no sockets.
final class GamepadInputProcessor: @unchecked Sendable {

    /// The XUSB button bits, identical across every Dish client.
    enum Buttons {
        static let dpadUp: UInt16 = 0x0001
        static let dpadDown: UInt16 = 0x0002
        static let dpadLeft: UInt16 = 0x0004
        static let dpadRight: UInt16 = 0x0008
        static let start: UInt16 = 0x0010
        static let back: UInt16 = 0x0020
        static let leftThumb: UInt16 = 0x0040
        static let rightThumb: UInt16 = 0x0080
        static let leftShoulder: UInt16 = 0x0100
        static let rightShoulder: UInt16 = 0x0200
        static let guide: UInt16 = 0x0400
        static let faceA: UInt16 = 0x1000
        static let faceB: UInt16 = 0x2000
        static let faceX: UInt16 = 0x4000
        static let faceY: UInt16 = 0x8000
    }

    typealias DeviceId = String
    typealias DeviceState = GamepadReport
    /// Each device's route, as the main actor resolved it.
    typealias RouteResolver = (_ deviceId: DeviceId) -> Route?

    /// Per-axis dead zones: a stick at or below `stickFlat` and a trigger at
    /// or below `triggerFlat` read as zero.
    struct Deadzones: Equatable {
        var stickFlat: Int16 = 0
        var triggerFlat: UInt8 = 0
    }

    /// The wire holds motion at or under this rate; a faster sensor is thinned.
    static let motionRateLimitHz: UInt64 = 250
    static let motionMinIntervalNs: UInt64 = 1_000_000_000 / motionRateLimitHz

    /// When the last report left, on the uptime clock; the keep-awake window
    /// reads it.
    let lastInputMs = AtomicInt(0)
    /// Every report handed to a sink, for the telemetry's sends.
    let sent = AtomicCounter()

    /// The feeds by device, each device's stored dead zones and the routes:
    /// written where a pad attaches or the routing changes, read by the main
    /// actor's ticks; never on a report.
    private let registry = LockedBox(FeedRegistry(), name: "input.feeds")

    private struct FeedRegistry {
        var feeds: [DeviceId: PadFeed] = [:]
        var deadzones: [DeviceId: Deadzones] = [:]
        var resolve: RouteResolver = { _ in nil }
    }

    // MARK: - Feeds

    /// The device's feed, made with its dead zones and its route on first use.
    func feed(for deviceId: DeviceId) -> PadFeed {
        registry.mutate { registry in
            if let feed = registry.feeds[deviceId] { return feed }
            let feed = PadFeed(deviceId: deviceId, lastInputMs: lastInputMs, sent: sent)
            feed.useDeadzones(registry.deadzones[deviceId] ?? Deadzones())
            feed.post(route: registry.resolve(deviceId))
            registry.feeds[deviceId] = feed
            return feed
        }
    }

    /// Every feed's route from now on, and the route of every feed made later.
    func route(_ resolve: @escaping RouteResolver) {
        registry.mutate { registry in
            registry.resolve = resolve
            for (deviceId, feed) in registry.feeds {
                feed.post(route: resolve(deviceId))
            }
        }
    }

    func setDeadzones(deviceId: DeviceId, _ zones: Deadzones) {
        registry.mutate { registry in
            registry.deadzones[deviceId] = zones
            registry.feeds[deviceId]?.useDeadzones(zones)
        }
    }

    /// The pad left: its feed routes nowhere, and a pad that comes back gets
    /// a fresh one whose counts start over.
    func remove(deviceId: DeviceId) {
        registry.mutate { registry in
            registry.deadzones.removeValue(forKey: deviceId)
            registry.feeds.removeValue(forKey: deviceId)?.post(route: nil)
        }
    }

    // MARK: - By device id, off the hot path

    /// The pads' own threads publish through their feeds; these look the feed
    /// up first, for the callers that hold only an id.
    func publish(deviceId: DeviceId, state: GamepadReport) {
        feed(for: deviceId).publish(state)
    }

    func publishMotion(deviceId: DeviceId, sample: MotionSample, nowNs: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        feed(for: deviceId).publishMotion(sample, nowNs: nowNs)
    }

    func publishTouchpad(deviceId: DeviceId, sample: TouchpadSample, nowNs: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        feed(for: deviceId).publishTouchpad(sample, nowNs: nowNs)
    }

    /// The main actor's battery timers: through the route it resolved, on
    /// the caller's thread.
    func publishBattery(deviceId: DeviceId, level: UInt8, statusRaw: UInt8) {
        guard let route = registry.get().resolve(deviceId) else { return }
        route.sink.sendBattery(level: level, status: BatteryStatus(rawValue: statusRaw) ?? .unknown)
    }

    /// Send a released report for every pad, so nothing stays held on the
    /// host when this process stops receiving events.
    func zeroAndSendAll() {
        let current = registry.get()
        for deviceId in current.feeds.keys {
            guard let route = current.resolve(deviceId) else { continue }
            sent.increment()
            route.sink.sendReport(.released)
        }
    }

    // MARK: - The main actor's reads

    /// What the pad last sent, read off its record; nil for a pad with no feed.
    func latestInput(_ deviceId: DeviceId) -> LatestInput? {
        registry.get().feeds[deviceId]?.record.read()
    }

    /// Each pad's published reports and admitted motion samples so far.
    func tallySnapshot() -> PadTally {
        var tally = PadTally()
        for (deviceId, feed) in registry.get().feeds {
            let reports = feed.record.reportCount
            let motion = feed.record.motionCount
            if reports > 0 { tally.reports[deviceId] = reports }
            if motion > 0 { tally.motion[deviceId] = motion }
        }
        return tally
    }
}

/// What each pad has produced so far: its published reports and its
/// admitted motion samples.
struct PadTally: Equatable {
    var reports: [String: UInt64] = [:]
    var motion: [String: UInt64] = [:]
}

// MARK: - Pure conversions

/// deg/s to the wire's int16 at ±2000 deg/s full scale, clamped.
@inline(__always)
func scaleGyro(_ degPerSec: Double) -> Int16 {
    let scaled = (degPerSec / 2000.0) * 32767.0
    return Int16(clamping: Int(scaled.rounded()))
}

/// g to the wire's int16 at ±4 g full scale, clamped.
@inline(__always)
func scaleAccel(_ gValue: Double) -> Int16 {
    let scaled = (gValue / 4.0) * 32767.0
    return Int16(clamping: Int(scaled.rounded()))
}

/// One IMU vector on three axes, in the unit its source reports.
struct MotionAxes: Equatable {
    var x: Double
    var y: Double
    var z: Double

    static let zero = MotionAxes(x: 0, y: 0, z: 0)
}

/// Convert a GCMotion-shaped reading to the wire frame. GameController's
/// `rotationRate` is rad/s with right-hand-rule signs and its `gravity` is
/// the gravitational load vector (a pad at rest reads -1 g up), so the wire's
/// specific force is `userAcceleration - gravity` and the axes map 1:1.
@inline(__always)
func gcMotionToWire(rotationRateRad: MotionAxes, gravity: MotionAxes, userAccel: MotionAxes) -> MotionSample {
    let radToDeg = 180.0 / Double.pi
    return MotionSample(
        gyroX: scaleGyro(rotationRateRad.x * radToDeg),
        gyroY: scaleGyro(rotationRateRad.y * radToDeg),
        gyroZ: scaleGyro(rotationRateRad.z * radToDeg),
        accelX: scaleAccel(userAccel.x - gravity.x),
        accelY: scaleAccel(userAccel.y - gravity.y),
        accelZ: scaleAccel(userAccel.z - gravity.z)
    )
}

/// A finger's wire tracking id bumps on each fresh contact (an up-to-down
/// edge) and holds otherwise; the wrap of a `UInt8` is harmless because only
/// the edge carries information.
@inline(__always)
func nextTouchpadTrackingId(wasActive: Bool, isActive: Bool, current: UInt8) -> UInt8 {
    let freshContact = !wasActive && isActive
    return freshContact ? current &+ 1 : current
}

/// GameController's centre-origin -1...1 touchpad axes to the wire's
/// centre-origin int16 with +y down, so y is negated.
@inline(__always)
func gcTouchpadAxisToWire(x: Float, y: Float) -> (x: Int16, y: Int16) {
    (x: scaleAxis(x, max: 32767), y: scaleAxis(-y, max: 32767))
}

/// Sticks at or below the flat read zero; triggers at or below theirs read
/// zero; buttons pass through.
@inline(__always)
func applyDeadzones(_ report: GamepadReport, _ zones: GamepadInputProcessor.Deadzones) -> GamepadReport {
    var out = report
    let stickFlat = Int32(zones.stickFlat)
    if abs(Int32(out.lx)) <= stickFlat { out.lx = 0 }
    if abs(Int32(out.ly)) <= stickFlat { out.ly = 0 }
    if abs(Int32(out.rx)) <= stickFlat { out.rx = 0 }
    if abs(Int32(out.ry)) <= stickFlat { out.ry = 0 }
    if out.lt <= zones.triggerFlat { out.lt = 0 }
    if out.rt <= zones.triggerFlat { out.rt = 0 }
    return out
}
