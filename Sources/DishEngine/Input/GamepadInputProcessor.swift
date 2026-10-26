// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import Foundation

/// Turns raw controller values into the wire's report, applies the per-device
/// dead zones and hands each report to the installed sender on the calling
/// thread. No framework imports and no sockets: the controller bridge builds
/// the full state on every change and the router owns the socket.
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

    /// Called on the caller's thread for every emitted report.
    typealias ReportSender = (_ deviceId: DeviceId, _ report: GamepadReport) -> Void
    /// Called on the caller's thread for every motion sample that passed the
    /// rate limit, with the delta since this device's previous emitted sample.
    typealias MotionSender = (_ deviceId: DeviceId, _ sample: MotionSample, _ timestampDeltaUs: UInt32) -> Void
    /// Called on the main actor for every battery snapshot.
    typealias BatterySender = (_ deviceId: DeviceId, _ level: UInt8, _ statusRaw: UInt8) -> Void
    /// Called on the caller's thread for every touchpad sample, with the
    /// sender-side uptime stamp the frame carries.
    typealias TouchpadSender = (_ deviceId: DeviceId, _ sample: TouchpadSample, _ eventTimeMs: UInt32) -> Void
    /// The inspector's taps, on the caller's thread: every report as the pad
    /// sent it and as it left for the host, every admitted motion sample,
    /// every touchpad sample.
    typealias ReportTap = (_ deviceId: DeviceId, _ raw: GamepadReport, _ filtered: GamepadReport) -> Void
    typealias MotionTap = (_ deviceId: DeviceId, _ sample: MotionSample) -> Void
    typealias TouchpadTap = (_ deviceId: DeviceId, _ sample: TouchpadSample) -> Void

    /// Per-axis dead zones: a stick at or below `stickFlat` and a trigger at
    /// or below `triggerFlat` read as zero.
    struct Deadzones: Equatable {
        var stickFlat: Int16 = 0
        var triggerFlat: UInt8 = 0
    }

    /// The wire holds motion at or under this rate; a faster sensor is thinned.
    static let motionRateLimitHz: UInt64 = 250
    private static let motionMinIntervalNs: UInt64 = 1_000_000_000 / motionRateLimitHz

    /// The senders are installed by the composition root and read on the
    /// controller callback threads; the boxes make that hand-off race-free.
    /// When the last report left, on the uptime clock; the keep-awake window
    /// reads it.
    let lastInputMs = AtomicInt(0)

    private let reportSenderBox = LockedBox<ReportSender?>(nil)
    private let motionSenderBox = LockedBox<MotionSender?>(nil)
    private let batterySenderBox = LockedBox<BatterySender?>(nil)
    private let touchpadSenderBox = LockedBox<TouchpadSender?>(nil)
    private let reportTapBox = LockedBox<ReportTap?>(nil)
    private let motionTapBox = LockedBox<MotionTap?>(nil)
    private let touchpadTapBox = LockedBox<TouchpadTap?>(nil)

    private var states: [DeviceId: GamepadReport] = [:]
    private var deadzones: [DeviceId: Deadzones] = [:]
    private var lastMotionTimestampNs: [DeviceId: UInt64] = [:]
    private let lock = NSLock()

    var reportSender: ReportSender? {
        get { reportSenderBox.get() }
        set { reportSenderBox.set(newValue) }
    }

    var motionSender: MotionSender? {
        get { motionSenderBox.get() }
        set { motionSenderBox.set(newValue) }
    }

    var batterySender: BatterySender? {
        get { batterySenderBox.get() }
        set { batterySenderBox.set(newValue) }
    }

    var touchpadSender: TouchpadSender? {
        get { touchpadSenderBox.get() }
        set { touchpadSenderBox.set(newValue) }
    }

    var reportTap: ReportTap? {
        get { reportTapBox.get() }
        set { reportTapBox.set(newValue) }
    }

    var motionTap: MotionTap? {
        get { motionTapBox.get() }
        set { motionTapBox.set(newValue) }
    }

    var touchpadTap: TouchpadTap? {
        get { touchpadTapBox.get() }
        set { touchpadTapBox.set(newValue) }
    }

    // MARK: - Reports

    func setDeadzones(deviceId: DeviceId, _ zones: Deadzones) {
        lock.lock()
        deadzones[deviceId] = zones
        lock.unlock()
    }

    /// Filter a full-state report through the device's dead zones, remember
    /// it, stamp the moment, and send it.
    func publish(deviceId: DeviceId, state: GamepadReport) {
        lock.lock()
        let zones = deadzones[deviceId] ?? Deadzones()
        let filtered = applyDeadzones(state, zones)
        states[deviceId] = filtered
        lock.unlock()
        lastInputMs.set(Int(uptimeMs()))
        reportTap?(deviceId, state, filtered)
        reportSender?(deviceId, filtered)
    }

    /// Send a released report for every known device, so nothing stays held
    /// on the host when this process stops receiving events.
    func zeroAndSendAll() {
        lock.lock()
        let ids = Array(states.keys)
        for id in ids {
            states[id] = .released
        }
        lock.unlock()
        for id in ids {
            reportSender?(id, .released)
        }
    }

    func remove(deviceId: DeviceId) {
        lock.lock()
        defer { lock.unlock() }
        states.removeValue(forKey: deviceId)
        deadzones.removeValue(forKey: deviceId)
        lastMotionTimestampNs.removeValue(forKey: deviceId)
    }

    // MARK: - Motion

    /// Forward a wire-scaled sample, thinned to the rate limit. The limit is
    /// measured from the last emitted sample, so a stream of drops never
    /// pushes the deadline forward.
    func publishMotion(deviceId: DeviceId, sample: MotionSample, nowNs: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        guard let deltaUs = admitMotion(deviceId: deviceId, nowNs: nowNs) else { return }
        motionTap?(deviceId, sample)
        motionSender?(deviceId, sample, deltaUs)
    }

    /// The delta to stamp on this sample, or nil when it falls inside the
    /// rate-limit window or the clock did not advance.
    private func admitMotion(deviceId: DeviceId, nowNs: UInt64) -> UInt32? {
        lock.lock()
        defer { lock.unlock() }
        guard let previous = lastMotionTimestampNs[deviceId] else {
            lastMotionTimestampNs[deviceId] = nowNs
            return 0
        }
        guard nowNs > previous else { return nil }
        let elapsedNs = nowNs - previous
        let insideTheWindow = elapsedNs < Self.motionMinIntervalNs
        if insideTheWindow { return nil }
        lastMotionTimestampNs[deviceId] = nowNs
        return UInt32(clamping: elapsedNs / 1000)
    }

    // MARK: - Battery and touchpad

    func publishBattery(deviceId: DeviceId, level: UInt8, statusRaw: UInt8) {
        batterySender?(deviceId, level, statusRaw)
    }

    /// Forward a touchpad sample stamped with the publish instant: the
    /// framework surfaces no per-event timestamp.
    func publishTouchpad(deviceId: DeviceId, sample: TouchpadSample, nowNs: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        touchpadTap?(deviceId, sample)
        touchpadSender?(deviceId, sample, UInt32(truncatingIfNeeded: nowNs / 1_000_000))
    }
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
