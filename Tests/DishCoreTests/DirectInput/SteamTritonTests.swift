// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import XCTest

/// The 2026 Steam Controller's input reports and the reports Dish sends it:
/// SDL's `SDL_hidapi_steam_triton.c` and `controller_structs.h` read byte by
/// byte, the button and axis mapping SDL's and the Linux `hid-steam` table's,
/// which agree.
final class SteamTritonTests: XCTestCase {

    private enum Button {
        static let buttonA: UInt32 = 0x0000_0001
        static let buttonB: UInt32 = 0x0000_0002
        static let buttonX: UInt32 = 0x0000_0004
        static let buttonY: UInt32 = 0x0000_0008
        static let quickAccess: UInt32 = 0x0000_0010
        static let r3: UInt32 = 0x0000_0020
        static let view: UInt32 = 0x0000_0040
        static let r4: UInt32 = 0x0000_0080
        static let r5: UInt32 = 0x0000_0100
        static let right: UInt32 = 0x0000_0200
        static let dpadDown: UInt32 = 0x0000_0400
        static let dpadRight: UInt32 = 0x0000_0800
        static let dpadLeft: UInt32 = 0x0000_1000
        static let dpadUp: UInt32 = 0x0000_2000
        static let menu: UInt32 = 0x0000_4000
        static let l3: UInt32 = 0x0000_8000
        static let steam: UInt32 = 0x0001_0000
        static let l4: UInt32 = 0x0002_0000
        static let l5: UInt32 = 0x0004_0000
        static let left: UInt32 = 0x0008_0000
        static let rightPadTouch: UInt32 = 0x0020_0000
        static let rightPadClick: UInt32 = 0x0040_0000
        static let rightTriggerClick: UInt32 = 0x0080_0000
        static let leftPadClick: UInt32 = 0x0400_0000
        static let leftTriggerClick: UInt32 = 0x0800_0000
        static let gripTouches: UInt32 = 0x3000_0000
    }

    private func report(_ bytes: TritonReportBytes) throws -> GamepadReport {
        guard case let .state(report, _) = bytes.decode() else {
            XCTFail("not a state report")
            return GamepadReport()
        }
        return report
    }

    private func motion(_ bytes: TritonReportBytes) -> MotionSample? {
        guard case let .state(_, motion) = bytes.decode() else { return nil }
        return motion
    }

    // MARK: - Buttons

    func testTheFaceAndShoulderButtonsMapByPosition() throws {
        let face = try report(.state(Button.buttonA | Button.buttonB | Button.buttonX | Button.buttonY))
        XCTAssertEqual(face.buttons, WireButtonWord([.faceA, .faceB, .faceX, .faceY]).rawValue)
        let shoulders = try report(.state(Button.left | Button.right))
        XCTAssertEqual(shoulders.buttons, WireButtonWord([.leftShoulder, .rightShoulder]).rawValue)
    }

    func testViewIsStartMenuIsBackAndSteamIsGuide() throws {
        XCTAssertEqual(try report(.state(Button.view)).buttons, WireButton.start.bit, "SDL's START and hid-steam's BTN_START")
        XCTAssertEqual(try report(.state(Button.menu)).buttons, WireButton.back.bit, "SDL's BACK and hid-steam's BTN_SELECT")
        XCTAssertEqual(try report(.state(Button.steam)).buttons, WireButton.guide.bit)
    }

    func testTheStickClicksAndTheDpad() throws {
        let clicks = try report(.state(Button.l3 | Button.r3)).buttons
        XCTAssertEqual(clicks, WireButtonWord([.leftThumb, .rightThumb]).rawValue)
        let dpad = try report(.state(Button.dpadUp | Button.dpadDown | Button.dpadLeft | Button.dpadRight)).buttons
        XCTAssertEqual(dpad, WireButtonWord([.dpadUp, .dpadDown, .dpadLeft, .dpadRight]).rawValue)
    }

    func testTheButtonsXusbHasNoBitForStayUnmapped() throws {
        let extras = Button.quickAccess | Button.r4 | Button.r5 | Button.l4 | Button.l5 | Button.rightPadTouch
            | Button.rightPadClick | Button.rightTriggerClick | Button.leftPadClick | Button.leftTriggerClick | Button.gripTouches
        XCTAssertEqual(try report(.state(extras)).buttons, 0, "no Share, paddles, pad clicks or trigger clicks on XUSB")
    }

    // MARK: - Axes

    func testTheSticksAreUpPositiveAsTheWireIs() throws {
        var bytes = TritonReportBytes.state()
        bytes.setLe16(10, -8000)
        bytes.setLe16(12, 12000)
        bytes.setLe16(14, 32767)
        bytes.setLe16(16, -32768)
        let sticks = try report(bytes)
        XCTAssertEqual([sticks.lx, sticks.ly, sticks.rx, sticks.ry], [-8000, 12000, 32767, -32768])
    }

    func testTheTriggersScaleFromTheirHalfRange() throws {
        var bytes = TritonReportBytes.state()
        bytes.setLe16(6, 32767)
        bytes.setLe16(8, 16384)
        let pulled = try report(bytes)
        XCTAssertEqual(pulled.lt, 255)
        XCTAssertEqual(pulled.rt, 127)
        bytes.setLe16(6, -20)
        XCTAssertEqual(try report(bytes).lt, 0, "a reading under the rest point is no pull")
    }

    // MARK: - Motion

    func testTheImuMapsSdlsAxesOntoTheWire() {
        var bytes = TritonReportBytes.state()
        for (offset, value) in [(34, 1000), (36, 2000), (38, 3000), (40, 4000), (42, 5000), (44, 6000)] {
            bytes.setLe16(offset, Int16(value))
        }
        let expected = MotionSample(gyroX: 3999, gyroY: 5999, gyroZ: -4999, accelX: 499, accelY: 1499, accelZ: -999)
        XCTAssertEqual(motion(bytes), expected, "pitch is gyro X, yaw gyro Z, roll minus gyro Y")
    }

    func testASilentImuBlockPublishesNoMotion() {
        XCTAssertNil(motion(.state(Button.buttonA)))
    }

    // MARK: - The report shapes

    func testTheBleAndTimestampStateReportsReadTheSameFields() {
        var plain = TritonReportBytes.state(Button.buttonA)
        plain.setLe16(10, 1234)
        plain.setLe16(44, 600)
        for reportId: UInt8 in [0x45, 0x47] {
            var other = plain
            other.bytes[0] = reportId
            XCTAssertEqual(other.decode(), plain.decode(), String(format: "report 0x%02X", reportId))
        }
    }

    func testTheFullStateReportWithItsQuaternionReadsTheSame() throws {
        var full = TritonReportBytes.state(Button.buttonB, length: 54)
        full.setLe16(46, 9999)
        XCTAssertEqual(try report(full).buttons, WireButton.faceB.bit)
    }

    func testAShortStateReportIsNothing() {
        XCTAssertNil(TritonReportBytes.state(Button.buttonA, length: 45).decode())
    }

    func testAnUnknownReportIdIsNothing() {
        XCTAssertNil(TritonReportBytes.state(Button.buttonA, reportId: 0x01).decode())
        XCTAssertNil(TritonReportBytes(bytes: []).decode())
    }

    // MARK: - Battery

    func testTheBatteryReportReadsItsPercentAndChargeState() {
        XCTAssertEqual(TritonReportBytes.battery(chargeState: 1, level: 64).decode(), .battery(PadBattery(level: 64, status: .discharging)))
        XCTAssertEqual(TritonReportBytes.battery(chargeState: 2, level: 30).decode(), .battery(PadBattery(level: 30, status: .charging)))
        XCTAssertEqual(TritonReportBytes.battery(chargeState: 4, level: 100).decode(), .battery(PadBattery(level: 100, status: .full)))
    }

    func testAChargeStateSdlCallsAnErrorIsUnknown() {
        for chargeState: UInt8 in [0, 3, 9] {
            XCTAssertEqual(
                TritonReportBytes.battery(chargeState: chargeState, level: 50).decode(),
                .battery(PadBattery(level: 50, status: .unknown))
            )
        }
    }

    func testAPercentPastFullReadsFull() {
        XCTAssertEqual(TritonReportBytes.battery(chargeState: 2, level: 180).decode(), .battery(PadBattery(level: 100, status: .charging)))
    }

    func testAShortBatteryReportIsNothing() {
        var short = TritonReportBytes.battery(chargeState: 1, level: 50)
        short.bytes.removeLast()
        XCTAssertNil(short.decode())
    }

    // MARK: - The receiver's events

    func testBothWirelessStatusReportsClassify() {
        for reportId: UInt8 in [0x79, 0x46] {
            XCTAssertEqual(TritonReportBytes.wireless(1, reportId: reportId).decode(), .link(.disconnected))
            XCTAssertEqual(TritonReportBytes.wireless(2, reportId: reportId).decode(), .link(.connected))
            XCTAssertNil(TritonReportBytes.wireless(3, reportId: reportId).decode(), "pairing is neither")
        }
        XCTAssertNil(TritonReportBytes(bytes: [0x79]).decode(), "a status with no state byte")
    }

    // MARK: - What Dish sends

    func testTheLizardOffReportIsOneSettingOnFeatureReportOne() {
        let report = tritonLizardOffReport()
        XCTAssertEqual(report.count, 64, "HID_FEATURE_REPORT_BYTES, the report id included")
        XCTAssertEqual(Array(report.prefix(6)), [0x01, 0x87, 0x03, 0x09, 0x00, 0x00], "SETTING_LIZARD_MODE = LIZARD_MODE_OFF")
        XCTAssertTrue(report.dropFirst(6).allSatisfy { $0 == 0 })
    }

    func testTheSensorsReportAsksForRawAccelAndGyro() {
        let report = tritonSensorsOnReport()
        XCTAssertEqual(report.count, 64)
        XCTAssertEqual(Array(report.prefix(6)), [0x01, 0x87, 0x03, 0x30, 0x18, 0x00], "SETTING_IMU_MODE = raw accel | raw gyro")
        XCTAssertTrue(report.dropFirst(6).allSatisfy { $0 == 0 })
    }

    func testTheRumbleReportCarriesBothMotorsLittleEndian() {
        let report = tritonRumbleReport(left: 0x1234, right: 0xABCD)
        XCTAssertEqual(
            report,
            [0x80, 0x00, 0x00, 0x00, 0x34, 0x12, 0x00, 0xCD, 0xAB, 0x00],
            "type 0, intensity 0, each side's speed and no gain"
        )
    }
}
