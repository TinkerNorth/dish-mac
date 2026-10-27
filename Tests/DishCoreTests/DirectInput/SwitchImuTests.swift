// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import XCTest

/// The Switch Pro's IMU frames: averaged, rotated onto the DualShock 4
/// convention and scaled by SDL's defaults. Android's axis signs; only pitch
/// and yaw were confirmed on hardware there.
final class SwitchImuTests: XCTestCase {

    private func motion(_ report: SwitchReportBytes) -> MotionSample? {
        report.decodeFresh(.pro)?.motion
    }

    private func motionWithOneAxis(at offset: Int, _ value: Int16) -> MotionSample? {
        var report = SwitchReportBytes(length: 25)
        report.setLe16(offset, value)
        return motion(report)
    }

    func testTheProAveragesItsImuFrames() {
        var three = SwitchReportBytes(length: 49)
        three.setLe16(13, 300)
        three.setLe16(25, 600)
        three.setLe16(37, 900)
        var mean = SwitchReportBytes(length: 25)
        mean.setLe16(13, 600)
        var first = SwitchReportBytes(length: 25)
        first.setLe16(13, 300)
        XCTAssertNotNil(motion(three))
        XCTAssertEqual(motion(three)?.accelZ, motion(mean)?.accelZ)
        XCTAssertNotEqual(motion(three)?.accelZ, motion(first)?.accelZ)
    }

    func testAtMostThreeFramesAreRead() {
        var three = SwitchReportBytes(length: 49)
        three.setLe16(13, 600)
        three.setLe16(25, 600)
        three.setLe16(37, 600)
        var four = SwitchReportBytes(length: 61)
        four.bytes.replaceSubrange(0 ..< 49, with: three.bytes)
        four.setLe16(49, 30000)
        XCTAssertEqual(motion(four), motion(three))
    }

    func testTheRotationLandsEachRawAxisOnItsWireAxis() {
        let pitch = motionWithOneAxis(at: 21, 4000)
        XCTAssertLessThan(pitch?.gyroX ?? 0, 0, "raw gyro Y is pitch, negated")
        XCTAssertEqual(pitch?.gyroY, 0)
        XCTAssertEqual(pitch?.gyroZ, 0)
        let yaw = motionWithOneAxis(at: 23, 4000)
        XCTAssertEqual(yaw?.gyroX, 0)
        XCTAssertGreaterThan(yaw?.gyroY ?? 0, 0, "raw gyro Z is yaw, upright")
        XCTAssertEqual(yaw?.gyroZ, 0)
        let roll = motionWithOneAxis(at: 19, 4000)
        XCTAssertEqual(roll?.gyroX, 0)
        XCTAssertEqual(roll?.gyroY, 0)
        XCTAssertLessThan(roll?.gyroZ ?? 0, 0, "raw gyro X is roll, negated")
        let accelRawX = motionWithOneAxis(at: 13, 4000)
        XCTAssertEqual([accelRawX?.accelX, accelRawX?.accelY], [0, 0])
        XCTAssertGreaterThan(accelRawX?.accelZ ?? 0, 0, "raw accel X is wire Z")
        let accelRawY = motionWithOneAxis(at: 15, 4000)
        XCTAssertGreaterThan(accelRawY?.accelX ?? 0, 0, "raw accel Y is wire X")
        XCTAssertEqual([accelRawY?.accelY, accelRawY?.accelZ], [0, 0])
        let accelRawZ = motionWithOneAxis(at: 17, 4000)
        XCTAssertGreaterThan(accelRawZ?.accelY ?? 0, 0, "raw accel Z is wire Y")
        XCTAssertEqual([accelRawZ?.accelX, accelRawZ?.accelZ], [0, 0])
    }

    func testSdlsDefaultScaleReachesTheWiresFullScale() {
        XCTAssertEqual(motionWithOneAxis(at: 23, 14284)?.gyroY, 16383, "1000 deg/s is half of the wire's 2000")
        XCTAssertEqual(motionWithOneAxis(at: 15, 8192)?.accelX, 16383, "2 g is half of the wire's 4")
    }

    func testAFullScaleRawReadingClampsInsteadOfWrapping() {
        XCTAssertEqual(motionWithOneAxis(at: 23, Int16.max)?.gyroY, Int16.max)
        XCTAssertEqual(motionWithOneAxis(at: 15, Int16.min)?.accelX, Int16.min)
        XCTAssertEqual(motionWithOneAxis(at: 21, Int16.min)?.gyroX, Int16.max, "negating Int16.min saturates")
    }

    func testAReportShorterThanOneFrameHasNoMotion() {
        XCTAssertNil(motion(SwitchReportBytes(length: 12)))
        XCTAssertNil(motion(SwitchReportBytes(length: 24)))
        XCTAssertNotNil(motion(SwitchReportBytes(length: 25)))
    }
}
