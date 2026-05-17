// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Foundation

/// Converts raw gamepad values into the XUSB report format the Satellite
/// server expects. Mirrors `GamepadInputProcessor.kt` on Android.
///
/// Pure logic: no framework imports, no network calls. The GameController
/// bridge (see `GameControllerInput.swift`) updates the per-device state
/// whenever a value changes and calls `trySend(deviceId:)`, which hands the
/// packed report to the registered `ReportSender`.
final class GamepadInputProcessor {

    // MARK: - XUSB button bits (identical to dish-android BUTTON_MAP).

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
        static let faceA: UInt16 = 0x1000
        static let faceB: UInt16 = 0x2000
        static let faceX: UInt16 = 0x4000
        static let faceY: UInt16 = 0x8000
    }

    typealias DeviceId = String

    /// Invoked every time a report is emitted. Called on the caller's thread
    /// (typically the GameController callback thread) for lowest latency.
    typealias ReportSender = (
        _ deviceId: DeviceId,
        _ wButtons: UInt16,
        _ lt: UInt8,
        _ rt: UInt8,
        _ lx: Int16,
        _ ly: Int16,
        _ rx: Int16,
        _ ry: Int16
    ) -> Void

    /// Invoked on every motion (IMU) sample. Same threading discipline as
    /// `ReportSender` — typically called from the `GCMotion` callback thread.
    /// Values are pre-scaled; see `scaleGyro` / `scaleAccel`.
    typealias MotionSender = (
        _ deviceId: DeviceId,
        _ gyroX: Int16, _ gyroY: Int16, _ gyroZ: Int16,
        _ accelX: Int16, _ accelY: Int16, _ accelZ: Int16,
        _ timestampDeltaUs: UInt32
    ) -> Void

    /// Invoked on every battery snapshot — connect, periodic 30 s tick,
    /// and on charging-state transitions. Called on the main actor.
    typealias BatterySender = (
        _ deviceId: DeviceId,
        _ level: UInt8,
        _ statusRaw: UInt8
    ) -> Void

    /// Invoked on every touchpad sample. Coordinates are pre-scaled int16.
    /// `fingerNId` is a monotonic per-finger tracking id, bumped by the bridge
    /// on each fresh contact (the protocol's per-finger id; GameController
    /// surfaces no native one).
    typealias TouchpadSender = (
        _ deviceId: DeviceId,
        _ finger0Active: Bool, _ finger0Id: UInt8, _ finger0X: Int16, _ finger0Y: Int16,
        _ finger1Active: Bool, _ finger1Id: UInt8, _ finger1X: Int16, _ finger1Y: Int16,
        _ buttonPressed: Bool
    ) -> Void

    var reportSender: ReportSender?
    var motionSender: MotionSender?
    var batterySender: BatterySender?
    var touchpadSender: TouchpadSender?

    /// Per-device state. Small struct, map lookups on every event — same
    /// design as the Android processor.
    struct DeviceState {
        var wButtons: UInt16 = 0
        var lt: UInt8 = 0
        var rt: UInt8 = 0
        var lx: Int16 = 0
        var ly: Int16 = 0
        var rx: Int16 = 0
        var ry: Int16 = 0
    }

    /// Per-axis deadzone thresholds. Values whose absolute magnitude is at or
    /// below the flat are zeroed before the report leaves the processor —
    /// mirrors the per-device flat values Android pulls out of
    /// `InputDevice.getMotionRange(axis).getFlat()`. macOS and Linux don't
    /// surface an OS-level equivalent, so the bridge installs a sensible
    /// default per controller and can override per-device when GC exposes
    /// `GCAxisInput.deadband` (macOS 14+).
    struct Deadzones: Equatable {
        var stickFlat: Int16 = 0
        var triggerFlat: UInt8 = 0
    }

    private var states: [DeviceId: DeviceState] = [:]
    private var deadzones: [DeviceId: Deadzones] = [:]
    private var lastMotionTimestampNs: [DeviceId: UInt64] = [:]
    private let lock = NSLock()

    /// Per-controller motion rate-limit cap. The wire protocol requires senders
    /// to hold MSG_MOTION at ≤ 250 Hz by default; GCMotion can fire at
    /// 500–1000 Hz on a wired DualSense, so `publishMotion` gates on this.
    static let motionRateLimitHz: UInt64 = 250
    private static let motionMinIntervalNs: UInt64 = 1_000_000_000 / motionRateLimitHz

    // MARK: - Mutators (called from GC callback thread)

    /// Push the per-axis deadzone thresholds for a device. Safe to call at any
    /// time; future `publish` calls for that device will apply the new values.
    func setDeadzones(deviceId: DeviceId, _ dz: Deadzones) {
        lock.lock()
        deadzones[deviceId] = dz
        lock.unlock()
    }

    /// Apply a fully-computed state + send. The caller (GameController bridge)
    /// reads every axis/button every time GCController fires and builds the
    /// complete `DeviceState` — that mirrors how Android's MotionEvent batch
    /// recomputes from scratch on every report.
    func publish(deviceId: DeviceId, state: DeviceState) {
        lock.lock()
        let dz = deadzones[deviceId] ?? Deadzones()
        let filtered = applyDeadzones(state, dz)
        states[deviceId] = filtered
        lock.unlock()
        reportSender?(
            deviceId,
            filtered.wButtons,
            filtered.lt,
            filtered.rt,
            filtered.lx,
            filtered.ly,
            filtered.rx,
            filtered.ry
        )
    }

    /// Emit a release-all report for every known device. Used on app
    /// deactivate / window-focus-lost so no button stays held server-side.
    func zeroAndSendAll() {
        lock.lock()
        let ids = Array(states.keys)
        for id in ids {
            states[id] = DeviceState()
        }
        lock.unlock()
        for id in ids {
            reportSender?(id, 0, 0, 0, 0, 0, 0, 0)
        }
    }

    /// Drop a device's state when the controller disconnects.
    func remove(deviceId: DeviceId) {
        lock.lock()
        defer { lock.unlock() }
        states.removeValue(forKey: deviceId)
        deadzones.removeValue(forKey: deviceId)
        lastMotionTimestampNs.removeValue(forKey: deviceId)
    }

    /// Forward a pre-scaled IMU sample. The caller (`GameControllerInput`)
    /// reads `GCMotion.gravity / userAcceleration / rotationRate` and converts
    /// to the wire-scale ints via `scaleGyro` / `scaleAccel`. We compute the
    /// inter-sample timestamp delta here so the GC bridge stays free of the
    /// per-device state.
    func publishMotion(
        deviceId: DeviceId,
        gyroX: Int16, gyroY: Int16, gyroZ: Int16,
        accelX: Int16, accelY: Int16, accelZ: Int16,
        nowNs: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) {
        // Per-controller 250 Hz rate-limit gate. A sample inside the gate
        // window is dropped *without* advancing `lastMotionTimestampNs`, so
        // the gate always measures from the last *emitted* packet and a hot
        // 1 kHz stream of drops can't push the deadline forward indefinitely.
        let deltaUs: UInt32
        do {
            lock.lock()
            defer { lock.unlock() }
            if let prev = lastMotionTimestampNs[deviceId] {
                guard nowNs > prev else { return } // same/backward clock — drop
                let elapsedNs = nowNs - prev
                if elapsedNs < Self.motionMinIntervalNs { return } // inside the gate
                // Saturating cast — a delta over UInt32.max µs (~71 minutes)
                // is not physically meaningful and the receiver tolerates 0.
                deltaUs = UInt32(clamping: elapsedNs / 1000)
            } else {
                deltaUs = 0 // first sample for this controller
            }
            lastMotionTimestampNs[deviceId] = nowNs
        }

        motionSender?(deviceId, gyroX, gyroY, gyroZ, accelX, accelY, accelZ, deltaUs)
    }

    /// Forward a battery snapshot. `level` is 0..100 inclusive or `0xFF`
    /// (unknown). `statusRaw` is one of the `SatelliteClient.BatteryStatus`
    /// raw values; the bridge resolves the enum before calling.
    func publishBattery(deviceId: DeviceId, level: UInt8, statusRaw: UInt8) {
        batterySender?(deviceId, level, statusRaw)
    }

    /// Forward a touchpad sample. Coordinates are already scaled to int16 by
    /// the bridge, and the per-finger tracking ids are already resolved by it.
    /// No deadzone / filtering is applied — a touchpad is an absolute pointing
    /// surface, not a self-centring stick.
    func publishTouchpad(
        deviceId: DeviceId,
        finger0Active: Bool, finger0Id: UInt8, finger0X: Int16, finger0Y: Int16,
        finger1Active: Bool, finger1Id: UInt8, finger1X: Int16, finger1Y: Int16,
        buttonPressed: Bool
    ) {
        touchpadSender?(
            deviceId,
            finger0Active,
            finger0Id,
            finger0X,
            finger0Y,
            finger1Active,
            finger1Id,
            finger1X,
            finger1Y,
            buttonPressed
        )
    }
}

// MARK: - Pure helpers (easily testable)

/// Scale a -1..1 axis float into a clamped 16-bit signed integer.
@inline(__always)
func scaleAxis(_ value: Float, max: Float) -> Int16 {
    Int16(clamping: Int(value * max))
}

/// Scale a 0..1 trigger float into a clamped 8-bit unsigned integer.
@inline(__always)
func scaleTrigger(_ value: Float) -> UInt8 {
    UInt8(clamping: Int((value * 255.0).rounded()))
}

/// Scale a deg/s gyro reading into the wire int16. Full scale ±2000 deg/s →
/// ±32767, matching the `MOTION_GYRO_SCALE_DEG_S` constant on the receiver.
/// Values beyond ±2000 deg/s clamp to the int16 limits.
@inline(__always)
func scaleGyro(_ degPerSec: Double) -> Int16 {
    let scaled = (degPerSec / 2000.0) * 32767.0
    return Int16(clamping: Int(scaled.rounded()))
}

/// Scale a g-units acceleration reading into the wire int16. Full scale ±4 g
/// → ±32767, matching `MOTION_ACCEL_SCALE_G` on the receiver. Values beyond
/// ±4 g clamp.
@inline(__always)
func scaleAccel(_ gValue: Double) -> Int16 {
    let scaled = (gValue / 4.0) * 32767.0
    return Int16(clamping: Int(scaled.rounded()))
}

/// Wire-ready IMU sample — six signed int16 in the protocol's scale/frame.
/// The output of `gcMotionToWire`; consumed by `GamepadInputProcessor.publishMotion`.
struct WireMotionSample: Equatable {
    var gyroX: Int16
    var gyroY: Int16
    var gyroZ: Int16
    var accelX: Int16
    var accelY: Int16
    var accelZ: Int16
}

/// Convert a `GCMotion`-shaped IMU reading into the MSG_MOTION wire frame.
/// Pure (no GameController import) so the GCMotion→wire mapping — the part the
/// receiver's de-scaling depends on — can be pinned by unit tests.
///
/// Inputs are exactly what `GCMotion` vends:
///   * `rotationRate` — rad/s, right-hand-rule signs on all three axes
///     (`GCRotationRate` doc comment in `GameController/GCMotion.h`).
///   * `gravity` / `userAcceleration` — g, in the controller reference frame;
///     `GCAcceleration`'s doc states a controller at rest with an axis pointing
///     up ("aligned with the azimuth (0,0,1)") reads `gravity` of `-1` on that
///     axis — i.e. `gravity` is the gravitational *load* vector (points down).
///
/// Axis frame: GameController's motion frame and the wire frame are both
/// right-handed with `+X` = right, `+Y` = up, `+Z` = toward the player, so the
/// axes map 1:1 with no per-axis rotation. See `pushMotion` for the citation.
///
/// Accel semantics: the wire wants *specific force* (proper acceleration) — a
/// pad at rest reads ≈ `+1 g` on the up axis. Specific force is
/// `userAcceleration - gravity` (NOT `gravity + userAcceleration`, which is the
/// raw accelerometer total that reads `-1 g` up at rest). Negating only the
/// gravity term flips the gravitational load into specific force while leaving
/// the linear-acceleration term intact:
///   * at rest, +Y up: userAccel 0, gravity -1 up → wire `0 - (-1) = +1 g` up.
///   * accelerating up at 1 g: userAccel +1, gravity -1 up → `+1 - (-1) = +2 g`.
@inline(__always)
func gcMotionToWire(
    rotationRateRadX: Double, rotationRateRadY: Double, rotationRateRadZ: Double,
    gravityX: Double, gravityY: Double, gravityZ: Double,
    userAccelX: Double, userAccelY: Double, userAccelZ: Double
) -> WireMotionSample {
    let radToDeg = 180.0 / Double.pi
    return WireMotionSample(
        gyroX: scaleGyro(rotationRateRadX * radToDeg),
        gyroY: scaleGyro(rotationRateRadY * radToDeg),
        gyroZ: scaleGyro(rotationRateRadZ * radToDeg),
        accelX: scaleAccel(userAccelX - gravityX),
        accelY: scaleAccel(userAccelY - gravityY),
        accelZ: scaleAccel(userAccelZ - gravityZ)
    )
}

/// Advance a finger's monotonic touchpad tracking id across one sample.
///
/// The MSG_TOUCHPAD protocol wants a per-finger id that increments on each
/// **new contact** so the receiver can tell "finger lifted then a new finger
/// touched" from "the same finger kept sliding". GameController exposes no
/// native id, so the bridge derives one from the active-edge: a `false → true`
/// transition (a fresh touch-down) bumps the id; every other case keeps it.
/// `UInt8` wraps freely — the protocol says ids "wrap freely".
///
/// Pure so the edge logic can be unit-tested without a live touchpad.
@inline(__always)
func nextTouchpadTrackingId(wasActive: Bool, isActive: Bool, current: UInt8) -> UInt8 {
    (!wasActive && isActive) ? current &+ 1 : current
}

/// Convert GameController's centre-origin `-1..1` touchpad axes into the
/// MSG_TOUCHPAD wire frame: centre-origin int16 with `+x` right and `+y`
/// *down*. GameController's direction-pad `+y` is up, so y is negated — the
/// flip §0x000C of `satellite/docs/protocol.md` requires of the macOS sender.
/// Pure so the negation can be unit-tested without a live touchpad.
@inline(__always)
func gcTouchpadAxisToWire(x: Float, y: Float) -> (x: Int16, y: Int16) {
    (x: scaleAxis(x, max: 32767), y: scaleAxis(-y, max: 32767))
}

/// Apply the per-axis deadzone thresholds in-place. Sticks: `|v| <= flat → 0`.
/// Triggers: `v <= flat → 0`. Buttons are passed through. Pure — extracted so
/// tests can pin the exact arithmetic without spinning up the processor.
@inline(__always)
func applyDeadzones(
    _ state: GamepadInputProcessor.DeviceState,
    _ dz: GamepadInputProcessor.Deadzones
) -> GamepadInputProcessor.DeviceState {
    var out = state
    let stickFlat = Int32(dz.stickFlat)
    if abs(Int32(out.lx)) <= stickFlat { out.lx = 0 }
    if abs(Int32(out.ly)) <= stickFlat { out.ly = 0 }
    if abs(Int32(out.rx)) <= stickFlat { out.rx = 0 }
    if abs(Int32(out.ry)) <= stickFlat { out.ry = 0 }
    if out.lt <= dz.triggerFlat { out.lt = 0 }
    if out.rt <= dz.triggerFlat { out.rt = 0 }
    return out
}
