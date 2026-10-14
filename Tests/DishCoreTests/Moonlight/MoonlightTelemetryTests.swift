// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import XCTest
@testable import DishCore

/// Unit conversions, the battery mapping, the host's motion ceiling, the
/// touch differ's events and the rumble fold.
final class MoonlightTelemetryTests: XCTestCase {

    func testTheUnitConversions() {
        XCTAssertEqual(MoonlightTelemetry.gyroDegreesPerSecond(32767), 2000, accuracy: 0.001)
        XCTAssertEqual(MoonlightTelemetry.gyroDegreesPerSecond(-32767), -2000, accuracy: 0.001)
        XCTAssertEqual(MoonlightTelemetry.gyroDegreesPerSecond(0), 0)
        XCTAssertEqual(MoonlightTelemetry.accelMetersPerSecondSquared(32767), 4 * 9.80665, accuracy: 0.001)
        XCTAssertEqual(MoonlightTelemetry.accelMetersPerSecondSquared(8192), 9.80665, accuracy: 0.01, "one g")
        XCTAssertEqual(MoonlightTelemetry.touchNormalized(Int16.min), 0)
        XCTAssertEqual(MoonlightTelemetry.touchNormalized(Int16.max), 1, accuracy: 0.0001)
        XCTAssertEqual(MoonlightTelemetry.touchNormalized(0), 0.5, accuracy: 0.0001)
    }

    func testTheBatteryMappingAndThePercentage() {
        XCTAssertEqual(MoonlightTelemetry.batteryState(.unknown), MoonlightBatteryState.unknown)
        XCTAssertEqual(MoonlightTelemetry.batteryState(.discharging), MoonlightBatteryState.discharging)
        XCTAssertEqual(MoonlightTelemetry.batteryState(.charging), MoonlightBatteryState.charging)
        XCTAssertEqual(MoonlightTelemetry.batteryState(.full), MoonlightBatteryState.full)
        XCTAssertEqual(
            MoonlightTelemetry.batteryState(.wired),
            MoonlightBatteryState.notPresent,
            "nothing to show, as the satellite treats it"
        )
        XCTAssertEqual(MoonlightTelemetry.batteryPercentage(0), 0)
        XCTAssertEqual(MoonlightTelemetry.batteryPercentage(100), 100)
        XCTAssertEqual(MoonlightTelemetry.batteryPercentage(101), MoonlightBatteryState.percentageUnknown)
        XCTAssertEqual(MoonlightTelemetry.batteryPercentage(-1), MoonlightBatteryState.percentageUnknown)
    }

    func testTheMotionGatePacesToTheHostsRateAndStopsAtZero() {
        var gate = MoonlightMotionGate()
        XCTAssertFalse(gate.wanted(controller: 0))
        XCTAssertFalse(gate.shouldSend(controller: 0, type: MoonlightMotionType.gyro, nowNs: 0), "nothing asked for")
        gate.onMotionRequest(controller: 0, rateHz: 100, type: MoonlightMotionType.gyro)
        XCTAssertTrue(gate.wanted(controller: 0, type: MoonlightMotionType.gyro))
        XCTAssertFalse(gate.wanted(controller: 0, type: MoonlightMotionType.accelerometer))
        XCTAssertTrue(gate.shouldSend(controller: 0, type: MoonlightMotionType.gyro, nowNs: 0))
        XCTAssertFalse(gate.shouldSend(controller: 0, type: MoonlightMotionType.gyro, nowNs: 5_000_000), "5 ms later: too soon at 100 Hz")
        XCTAssertTrue(gate.shouldSend(controller: 0, type: MoonlightMotionType.gyro, nowNs: 10_000_000))
        gate.onMotionRequest(controller: 0, rateHz: 200, type: MoonlightMotionType.gyro)
        XCTAssertTrue(gate.shouldSend(controller: 0, type: MoonlightMotionType.gyro, nowNs: 15_000_000), "the rate moved")
        gate.onMotionRequest(controller: 0, rateHz: 0, type: MoonlightMotionType.gyro)
        XCTAssertFalse(gate.wanted(controller: 0))
        gate.onMotionRequest(controller: 1, rateHz: 50, type: MoonlightMotionType.accelerometer)
        gate.onMotionRequest(controller: 2, rateHz: 50, type: MoonlightMotionType.accelerometer)
        gate.clear(controller: 1)
        XCTAssertFalse(gate.wanted(controller: 1))
        XCTAssertTrue(gate.wanted(controller: 2))
        gate.clearAll()
        XCTAssertFalse(gate.wanted(controller: 2))
    }

    func testTheTouchDifferEmitsDownMoveUpAndARetrack() {
        var differ = MoonlightTouchDiffer()
        XCTAssertEqual(
            differ.diff(finger: 0, active: true, id: 7, x: 0.5, y: 0.25),
            [MoonlightTouchEmission(event: MoonlightTouchEvent.down, pointerId: 7, x: 0.5, y: 0.25, pressure: 1)]
        )
        XCTAssertEqual(differ.diff(finger: 0, active: true, id: 7, x: 0.5, y: 0.25), [], "nothing changed")
        XCTAssertEqual(
            differ.diff(finger: 0, active: true, id: 7, x: 0.6, y: 0.25),
            [MoonlightTouchEmission(event: MoonlightTouchEvent.move, pointerId: 7, x: 0.6, y: 0.25, pressure: 1)]
        )
        XCTAssertEqual(
            differ.diff(finger: 0, active: true, id: 8, x: 0.1, y: 0.1),
            [
                MoonlightTouchEmission(event: MoonlightTouchEvent.up, pointerId: 7, x: 0.6, y: 0.25, pressure: 0),
                MoonlightTouchEmission(event: MoonlightTouchEvent.down, pointerId: 8, x: 0.1, y: 0.1, pressure: 1)
            ],
            "a new id on an active finger is a lift at the last place and a fresh contact"
        )
        XCTAssertEqual(
            differ.diff(finger: 0, active: false, id: 0, x: 0, y: 0),
            [MoonlightTouchEmission(event: MoonlightTouchEvent.up, pointerId: 8, x: 0.1, y: 0.1, pressure: 0)],
            "the lift names the contact as it was last held"
        )
        XCTAssertEqual(differ.diff(finger: 0, active: false, id: 0, x: 0, y: 0), [])
        XCTAssertEqual(differ.diff(finger: 1, active: true, id: 3, x: 0, y: 1).count, 1, "the second finger is its own")
        XCTAssertEqual(differ.diff(finger: 2, active: true, id: 3, x: 0, y: 1), [], "two fingers and no more")
        differ.reset()
        XCTAssertEqual(
            differ.diff(finger: 1, active: true, id: 3, x: 0, y: 1).first?.event,
            MoonlightTouchEvent.down,
            "reset forgets every contact"
        )
    }

    func testTheRumbleFoldIsAPerMotorMaximum() {
        let mix = MoonlightRumbleMix().withBody(strong: 1000, weak: 200).withTriggers(left: 300, right: 900)
        XCTAssertEqual(mix.mixed.strong, 1000)
        XCTAssertEqual(mix.mixed.weak, 900)
        let triggersStopped = mix.withTriggers(left: 0, right: 0)
        XCTAssertEqual(triggersStopped.mixed.strong, 1000, "a trigger update never cancels a body rumble")
        XCTAssertEqual(triggersStopped.mixed.weak, 200)
        XCTAssertEqual(MoonlightRumbleMix().mixed.strong, 0)
        XCTAssertEqual(
            MoonlightRumbleMix().withBody(strong: 0, weak: 0).withTriggers(left: 65535, right: 1).mixed.strong,
            65535,
            "no sum, no saturation"
        )
    }
}
