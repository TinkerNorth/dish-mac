// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import XCTest

/// The Switch pads' 12-bit sticks: Android's dead zone and per-side
/// auto-ranging reach, up-positive on the wire.
final class SwitchSticksTests: XCTestCase {

    private let center = SwitchReportBytes.center
    private let deadzone = SwitchReportBytes.deadzone
    private let rawMax = SwitchReportBytes.rawMax

    private func sticks(_ calibration: inout SwitchStickCalibration, lx: UInt16, ly: UInt16, rx: UInt16, ry: UInt16) -> GamepadReport? {
        var report = SwitchReportBytes()
        report.setSticks(lx: lx, ly: ly, rx: rx, ry: ry)
        return report.decode(.pro, calibration: &calibration)?.report
    }

    func testTwelveBitPackingUnpacksBothAxesOfBothSticks() {
        var calibration = SwitchStickCalibration()
        let state = sticks(&calibration, lx: rawMax, ly: 0, rx: center, ry: rawMax)
        XCTAssertEqual(state?.lx, 32767)
        XCTAssertEqual(state?.ly, -32768)
        XCTAssertEqual(state?.rx, 0)
        XCTAssertEqual(state?.ry, 32767)
    }

    /// The pad's raw Y grows when the stick is pushed up and the wire is
    /// up-positive, so nothing is inverted (unlike HID's down-positive Y).
    func testARawYAboveCentreIsUpPositiveOnTheWire() {
        var calibration = SwitchStickCalibration()
        let pushedUp = sticks(&calibration, lx: center, ly: center + 1000, rx: center, ry: center + 1000)
        XCTAssertGreaterThan(pushedUp?.ly ?? 0, 0)
        XCTAssertGreaterThan(pushedUp?.ry ?? 0, 0)
        let pulledDown = sticks(&calibration, lx: center, ly: center - 1000, rx: center, ry: center - 1000)
        XCTAssertLessThan(pulledDown?.ly ?? 0, 0)
        XCTAssertLessThan(pulledDown?.ry ?? 0, 0)
    }

    func testARestingOffsetInsideTheDeadzoneReadsCentre() {
        var calibration = SwitchStickCalibration()
        let state = sticks(&calibration, lx: center + deadzone, ly: center - deadzone, rx: center, ry: center + deadzone + 1)
        XCTAssertEqual(state?.lx, 0)
        XCTAssertEqual(state?.ly, 0)
        XCTAssertEqual(state?.rx, 0)
        XCTAssertEqual(state?.ry, 32, "one count past the dead zone against the seed reach: 1 * 32767 / 1000")
    }

    func testALearnedReachStretchesToTheRail() {
        var calibration = SwitchStickCalibration()
        let partial = center + deadzone + 500
        XCTAssertEqual(sticks(&calibration, lx: partial, ly: center, rx: center, ry: center)?.lx, 16383, "500 counts against the seed")
        XCTAssertEqual(sticks(&calibration, lx: rawMax, ly: center, rx: center, ry: center)?.lx, 32767)
        XCTAssertEqual(calibration.lx.positive, 1727, "4095 - 2048 - 320")
        XCTAssertEqual(
            sticks(&calibration, lx: partial, ly: center, rx: center, ry: center)?.lx,
            9486,
            "the same 500 against the learned reach"
        )
    }

    func testEachSideOfEachAxisLearnsItsOwnReach() {
        var calibration = SwitchStickCalibration()
        XCTAssertEqual(sticks(&calibration, lx: rawMax, ly: center, rx: center, ry: center)?.lx, 32767)
        XCTAssertEqual(calibration.lx.positive, 1727)
        XCTAssertEqual(calibration.lx.negative, SwitchAxisReach.seed)
        XCTAssertEqual(sticks(&calibration, lx: center - deadzone - 500, ly: center, rx: center, ry: center)?.lx, -16384)
        XCTAssertEqual(calibration.ly, SwitchAxisReach())
        XCTAssertEqual(calibration.rx, SwitchAxisReach())
        XCTAssertEqual(calibration.ry, SwitchAxisReach())
    }

    func testAFreshCalibrationStartsFromTheSeedOnEverySide() {
        let calibration = SwitchStickCalibration()
        XCTAssertEqual(SwitchAxisReach.seed, 1000)
        for axis in [calibration.lx, calibration.ly, calibration.rx, calibration.ry] {
            XCTAssertEqual(axis, SwitchAxisReach(positive: 1000, negative: 1000))
        }
    }
}
