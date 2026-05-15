// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import XCTest
@testable import Dish

/// Coverage for the motion + battery sender pipeline:
///
///   * Pure scale helpers (`scaleGyro`, `scaleAccel`) — including bounds and
///     clamping behaviour, since the receiver derives its scale constants
///     from the same convention and a drift here is silently catastrophic.
///   * `GamepadInputProcessor.publishMotion` — timestamp-delta computation,
///     per-device isolation, sender forwarding.
///   * `GamepadInputProcessor.publishBattery` — straight pass-through to
///     the configured sender.
///
/// The full I/O path (UDP encrypt + send) is intentionally out of scope here;
/// it would require driving a real socket. The wire packing is exercised by
/// `SatelliteClientMotionBatteryTests` (this file's sibling).
final class MotionBatteryProcessorTests: XCTestCase {

    // MARK: - scaleGyro

    func testScaleGyroZero() {
        XCTAssertEqual(scaleGyro(0), 0)
    }

    func testScaleGyroFullScalePositive() {
        // ±2000 deg/s = full scale per the protocol. We allow ±1 LSB tolerance
        // because of integer rounding in the scaler.
        let v = scaleGyro(2000)
        XCTAssertGreaterThanOrEqual(v, 32766)
        XCTAssertLessThanOrEqual(v, 32767)
    }

    func testScaleGyroFullScaleNegative() {
        let v = scaleGyro(-2000)
        XCTAssertGreaterThanOrEqual(v, -32767)
        XCTAssertLessThanOrEqual(v, -32766)
    }

    func testScaleGyroClampsOverflowPositive() {
        // 4000 deg/s would map to 65534 LSBs; must clamp to int16 max.
        XCTAssertEqual(scaleGyro(4000), Int16.max)
    }

    func testScaleGyroClampsOverflowNegative() {
        XCTAssertEqual(scaleGyro(-4000), Int16.min)
    }

    func testScaleGyroQuarterScale() {
        // 500 deg/s → ~25% of full scale → ~8192 LSBs. We accept ±1 for
        // rounding; a wider drift would mean the scale constant changed.
        let v = scaleGyro(500)
        XCTAssertGreaterThanOrEqual(v, 8191)
        XCTAssertLessThanOrEqual(v, 8193)
    }

    // MARK: - scaleAccel

    func testScaleAccelZero() {
        XCTAssertEqual(scaleAccel(0), 0)
    }

    func testScaleAccelOneG() {
        // 1 g out of ±4 g full-scale → 32767 / 4 ≈ 8192 LSBs, within ±1.
        let v = scaleAccel(1)
        XCTAssertGreaterThanOrEqual(v, 8191)
        XCTAssertLessThanOrEqual(v, 8193)
    }

    func testScaleAccelFullScalePositive() {
        let v = scaleAccel(4)
        XCTAssertGreaterThanOrEqual(v, 32766)
        XCTAssertLessThanOrEqual(v, 32767)
    }

    func testScaleAccelFullScaleNegative() {
        let v = scaleAccel(-4)
        XCTAssertGreaterThanOrEqual(v, -32767)
        XCTAssertLessThanOrEqual(v, -32766)
    }

    func testScaleAccelClampsOverflow() {
        XCTAssertEqual(scaleAccel(8), Int16.max)
        XCTAssertEqual(scaleAccel(-8), Int16.min)
    }

    // MARK: - publishMotion timestamp-delta

    private struct CapturedMotion: Equatable {
        let id: String
        let gx: Int16; let gy: Int16; let gz: Int16
        let ax: Int16; let ay: Int16; let az: Int16
        let dtUs: UInt32
    }

    private func makeProcessorWithMotionCapture(
        _ sink: @escaping (CapturedMotion) -> Void
    ) -> GamepadInputProcessor {
        let proc = GamepadInputProcessor()
        proc.motionSender = { id, gx, gy, gz, ax, ay, az, dt in
            sink(CapturedMotion(id: id, gx: gx, gy: gy, gz: gz, ax: ax, ay: ay, az: az, dtUs: dt))
        }
        return proc
    }

    func testPublishMotionFirstSampleHasZeroDelta() {
        var captured: CapturedMotion?
        let proc = makeProcessorWithMotionCapture { captured = $0 }
        proc.publishMotion(
            deviceId: "pad",
            gyroX: 100, gyroY: 200, gyroZ: 300,
            accelX: 400, accelY: 500, accelZ: 600,
            nowNs: 1_000_000_000
        )
        XCTAssertNotNil(captured)
        XCTAssertEqual(captured?.dtUs, 0)
    }

    func testPublishMotionSubsequentSampleComputesDelta() {
        var samples: [CapturedMotion] = []
        let proc = makeProcessorWithMotionCapture { samples.append($0) }
        proc.publishMotion(
            deviceId: "pad",
            gyroX: 0, gyroY: 0, gyroZ: 0, accelX: 0, accelY: 0, accelZ: 0,
            nowNs: 1_000_000_000
        )
        // 5 ms later — 5_000_000 ns = 5_000 µs.
        proc.publishMotion(
            deviceId: "pad",
            gyroX: 0, gyroY: 0, gyroZ: 0, accelX: 0, accelY: 0, accelZ: 0,
            nowNs: 1_005_000_000
        )
        XCTAssertEqual(samples.count, 2)
        XCTAssertEqual(samples[0].dtUs, 0)
        XCTAssertEqual(samples[1].dtUs, 5_000)
    }

    func testPublishMotionDeltaIsPerDevice() {
        var samples: [CapturedMotion] = []
        let proc = makeProcessorWithMotionCapture { samples.append($0) }
        proc.publishMotion(
            deviceId: "padA",
            gyroX: 0, gyroY: 0, gyroZ: 0, accelX: 0, accelY: 0, accelZ: 0,
            nowNs: 1_000_000_000
        )
        proc.publishMotion(
            deviceId: "padB",
            gyroX: 0, gyroY: 0, gyroZ: 0, accelX: 0, accelY: 0, accelZ: 0,
            nowNs: 1_010_000_000
        )
        // padA's second sample should compute delta off padA's t0, not padB's.
        proc.publishMotion(
            deviceId: "padA",
            gyroX: 0, gyroY: 0, gyroZ: 0, accelX: 0, accelY: 0, accelZ: 0,
            nowNs: 1_020_000_000
        )
        XCTAssertEqual(samples.count, 3)
        XCTAssertEqual(samples[0].dtUs, 0)
        XCTAssertEqual(samples[1].dtUs, 0) // first padB sample
        XCTAssertEqual(samples[2].dtUs, 20_000) // 20 ms after padA's first
    }

    func testPublishMotionRemoveClearsTimestampHistory() {
        var samples: [CapturedMotion] = []
        let proc = makeProcessorWithMotionCapture { samples.append($0) }
        proc.publishMotion(
            deviceId: "pad",
            gyroX: 0, gyroY: 0, gyroZ: 0, accelX: 0, accelY: 0, accelZ: 0,
            nowNs: 1_000_000_000
        )
        proc.remove(deviceId: "pad")
        // Re-add and re-publish; first new sample should be a "first" again
        // (delta 0), not a 5-second-stale delta.
        proc.publishMotion(
            deviceId: "pad",
            gyroX: 0, gyroY: 0, gyroZ: 0, accelX: 0, accelY: 0, accelZ: 0,
            nowNs: 6_000_000_000
        )
        XCTAssertEqual(samples.count, 2)
        XCTAssertEqual(samples[1].dtUs, 0)
    }

    func testPublishMotionForwardsScaledValues() {
        var captured: CapturedMotion?
        let proc = makeProcessorWithMotionCapture { captured = $0 }
        proc.publishMotion(
            deviceId: "pad",
            gyroX: 1234, gyroY: -567, gyroZ: 89,
            accelX: 100, accelY: -200, accelZ: 16384,
            nowNs: 1_000_000_000
        )
        XCTAssertEqual(captured?.gx, 1234)
        XCTAssertEqual(captured?.gy, -567)
        XCTAssertEqual(captured?.gz, 89)
        XCTAssertEqual(captured?.ax, 100)
        XCTAssertEqual(captured?.ay, -200)
        XCTAssertEqual(captured?.az, 16384) // ~+2 g, controller resting screen-up
    }

    // MARK: - publishBattery

    private struct CapturedBattery: Equatable {
        let id: String
        let level: UInt8
        let statusRaw: UInt8
    }

    func testPublishBatteryForwardsToSender() {
        var captured: CapturedBattery?
        let proc = GamepadInputProcessor()
        proc.batterySender = { id, lv, st in
            captured = CapturedBattery(id: id, level: lv, statusRaw: st)
        }
        proc.publishBattery(deviceId: "pad", level: 73, statusRaw: 1)
        XCTAssertEqual(captured, CapturedBattery(id: "pad", level: 73, statusRaw: 1))
    }

    func testPublishBatteryUnknownLevelPassesThrough() {
        var captured: CapturedBattery?
        let proc = GamepadInputProcessor()
        proc.batterySender = { id, lv, st in
            captured = CapturedBattery(id: id, level: lv, statusRaw: st)
        }
        proc.publishBattery(deviceId: "pad", level: 0xFF, statusRaw: 2)
        XCTAssertEqual(captured?.level, 0xFF)
        XCTAssertEqual(captured?.statusRaw, 2)
    }

    func testPublishBatteryDoesNotFireWithoutSender() {
        // No sender installed. Should not crash; should silently no-op.
        let proc = GamepadInputProcessor()
        proc.publishBattery(deviceId: "pad", level: 50, statusRaw: 1)
    }

    // MARK: - BatteryStatus enum (wire contract)

    func testBatteryStatusEnumWireValues() {
        XCTAssertEqual(SatelliteClient.BatteryStatus.unknown.rawValue, 0)
        XCTAssertEqual(SatelliteClient.BatteryStatus.discharging.rawValue, 1)
        XCTAssertEqual(SatelliteClient.BatteryStatus.charging.rawValue, 2)
        XCTAssertEqual(SatelliteClient.BatteryStatus.full.rawValue, 3)
        XCTAssertEqual(SatelliteClient.BatteryStatus.wired.rawValue, 4)
    }

    func testBatteryStatusInitFromRaw() {
        XCTAssertEqual(SatelliteClient.BatteryStatus(rawValue: 0), .unknown)
        XCTAssertEqual(SatelliteClient.BatteryStatus(rawValue: 4), .wired)
        XCTAssertNil(SatelliteClient.BatteryStatus(rawValue: 5))
    }
}
