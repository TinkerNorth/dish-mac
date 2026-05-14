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

    var reportSender: ReportSender?

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
    private let lock = NSLock()

    // MARK: - Telemetry

    private(set) var telEventCount = 0
    private(set) var telSendCount = 0
    private(set) var telTotalSent: UInt64 = 0

    struct TelemetrySnapshot { let events: Int
        let sends: Int
        let totalSent: UInt64
    }

    func drainTelemetry() -> TelemetrySnapshot {
        lock.lock()
        defer { lock.unlock() }
        let snap = TelemetrySnapshot(
            events: telEventCount,
            sends: telSendCount,
            totalSent: telTotalSent
        )
        telEventCount = 0
        telSendCount = 0
        return snap
    }

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
        telEventCount += 1
        telSendCount += 1
        telTotalSent &+= 1
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
    }
}

// MARK: - Pure helpers (easily testable)

/// Scale a -1..1 axis float into a clamped 16-bit signed integer.
@inline(__always)
func scaleAxis(_ value: Float, max: Float) -> Int16 {
    let scaled = Int(value * max)
    return Int16(clamping: max > 0 ? scaled : scaled)
}

/// Scale a 0..1 trigger float into a clamped 8-bit unsigned integer.
@inline(__always)
func scaleTrigger(_ value: Float) -> UInt8 {
    UInt8(clamping: Int((value * 255.0).rounded()))
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
