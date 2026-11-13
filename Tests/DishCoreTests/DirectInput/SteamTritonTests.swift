// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import XCTest

/// The 2026 Steam Controller's input reports and the reports Dish sends it:
/// SDL's `SDL_hidapi_steam_triton.c` and `controller_structs.h` read byte by
/// byte, the button and axis mapping SDL's and the Linux `hid-steam` table's,
/// which agree, and motion once per IMU tick, as SDL publishes it.
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
        static let rightStickTouch: UInt32 = 0x0010_0000
        static let rightPadTouch: UInt32 = 0x0020_0000
        static let rightPadClick: UInt32 = 0x0040_0000
        static let rightTriggerClick: UInt32 = 0x0080_0000
        static let leftStickTouch: UInt32 = 0x0100_0000
        static let leftPadTouch: UInt32 = 0x0200_0000
        static let leftPadClick: UInt32 = 0x0400_0000
        static let leftTriggerClick: UInt32 = 0x0800_0000
        static let rightGripTouch: UInt32 = 0x1000_0000
        static let leftGripTouch: UInt32 = 0x2000_0000
    }

    /// Each extra bit and the extended button SDL names it.
    private static let extraRows: [(bit: UInt32, ext: UInt32)] = [
        (Button.quickAccess, ProtocolConstants.extButtonMisc1),
        (Button.r4, ProtocolConstants.extButtonRightPaddle1),
        (Button.l4, ProtocolConstants.extButtonLeftPaddle1),
        (Button.r5, ProtocolConstants.extButtonRightPaddle2),
        (Button.l5, ProtocolConstants.extButtonLeftPaddle2),
        (Button.leftPadClick, ProtocolConstants.extButtonLeftPadClick),
        (Button.rightPadClick, ProtocolConstants.extButtonRightPadClick),
        (Button.leftTriggerClick, ProtocolConstants.extButtonLeftTriggerClick),
        (Button.rightTriggerClick, ProtocolConstants.extButtonRightTriggerClick),
        (Button.leftStickTouch, ProtocolConstants.extButtonLeftStickTouch),
        (Button.rightStickTouch, ProtocolConstants.extButtonRightStickTouch),
        (Button.leftGripTouch, ProtocolConstants.extButtonLeftGripTouch),
        (Button.rightGripTouch, ProtocolConstants.extButtonRightGripTouch)
    ]

    private static let stillSample = MotionSample(gyroX: 0, gyroY: 0, gyroZ: 0, accelX: 0, accelY: 0, accelZ: 0)

    private func report(_ bytes: TritonReportBytes) throws -> GamepadReport {
        guard case let .state(report, _) = bytes.decode() else {
            XCTFail("not a state report")
            return GamepadReport()
        }
        return report
    }

    private func motion(_ reading: SteamReading?) -> MotionSample? {
        guard case let .state(_, motion) = reading else { return nil }
        return motion
    }

    /// Each report's motion through one pad's carry, in order.
    private func motions(_ reports: [TritonReportBytes]) -> [MotionSample?] {
        var carry = TritonCarry()
        return reports.map { motion($0.decode(carry: &carry)) }
    }

    /// A state report on `imuTick` whose gyro X reads `gyroX`.
    private func sample(imuTick: UInt32, gyroX: Int16, reportId: UInt8 = 0x42) -> TritonReportBytes {
        var bytes = TritonReportBytes.state(reportId: reportId, imuTick: imuTick)
        bytes.setLe16(40, gyroX)
        return bytes
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

    func testEachExtraBitIsItsSdlNamedExtendedButtonAndNoXusbButton() throws {
        for row in Self.extraRows {
            let decoded = try report(.state(row.bit))
            XCTAssertEqual(decoded.extButtons, row.ext, "bit \(String(row.bit, radix: 16))")
            XCTAssertEqual(decoded.buttons, 0, "bit \(String(row.bit, radix: 16)) presses no XUSB button")
        }
    }

    func testEveryExtraRidesTheWordAtOnce() throws {
        let everyBit = Self.extraRows.reduce(UInt32(0)) { $0 | $1.bit }
        XCTAssertEqual(try report(.state(everyBit)).extButtons, ProtocolConstants.extButtonsKnownMask)
    }

    func testThePadTouchesAndTheMappedButtonsLeaveTheWordClear() throws {
        let touches = Button.leftPadTouch | Button.rightPadTouch
        XCTAssertEqual(try report(.state(touches)).extButtons, 0, "the pad touches have no slot in the word")
        let mapped = Button.buttonA | Button.buttonB | Button.buttonX | Button.buttonY | Button.left | Button.right | Button.view
            | Button.menu | Button.steam | Button.l3 | Button.r3 | Button.dpadUp | Button.dpadDown | Button.dpadLeft | Button.dpadRight
        XCTAssertEqual(try report(.state(mapped)).extButtons, 0)
    }

    func testTheBleAndTimestampReportsCarryTheSameWord() throws {
        let bits = Button.quickAccess | Button.r4 | Button.l5
        let expected = ProtocolConstants.extButtonMisc1 | ProtocolConstants.extButtonRightPaddle1 | ProtocolConstants.extButtonLeftPaddle2
        XCTAssertEqual(try report(.state(bits, reportId: 0x45)).extButtons, expected)
        XCTAssertEqual(try report(.state(bits, reportId: 0x47)).extButtons, expected)
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
        var bytes = TritonReportBytes.state(imuTick: 1)
        for (offset, value) in [(34, 1000), (36, 2000), (38, 3000), (40, 4000), (42, 5000), (44, 6000)] {
            bytes.setLe16(offset, Int16(value))
        }
        let expected = MotionSample(gyroX: 3999, gyroY: 5999, gyroZ: -4999, accelX: 499, accelY: 1499, accelZ: -999)
        XCTAssertEqual(motion(bytes.decode()), expected, "pitch is gyro X, yaw gyro Z, roll minus gyro Y")
    }

    func testAReportThatRepeatsTheImuTickPublishesNoMotionAgain() {
        let repeated = sample(imuTick: 7, gyroX: 100)
        XCTAssertEqual(
            motions([repeated, repeated]).map { $0?.gyroX },
            [99, nil],
            "the host has the sample; the report is input, not motion"
        )
    }

    func testAChangedImuTickPublishesTheNextSample() {
        let first = sample(imuTick: 7, gyroX: 100)
        let next = sample(imuTick: 8, gyroX: 200)
        XCTAssertEqual(motions([first, next]).map { $0?.gyroX }, [99, 199])
    }

    func testAnAllZeroImuBlockOnANewTickIsPublishedAsSdlPublishesIt() {
        let still = TritonReportBytes.state(imuTick: 5)
        XCTAssertEqual(motions([still, still]), [Self.stillSample, nil], "a pad at rest reads zero; the tick says the sample is new")
    }

    func testTheCarryStartsAtTickZeroAsSdlsLastTickDoes() {
        XCTAssertEqual(motions([sample(imuTick: 0, gyroX: 100), sample(imuTick: 1, gyroX: 100)]).map { $0?.gyroX }, [nil, 99])
    }

    func testTheTickIsFourBytesAtThirtyOrTwoAtThirtyTwoByReportShape() {
        for reportId: UInt8 in [0x42, 0x45] {
            let first = TritonReportBytes.state(reportId: reportId, imuTick: 9)
            var lowHalf = first
            lowHalf.setLe16(30, 10)
            XCTAssertEqual(
                motions([first, lowHalf]).map { $0 != nil },
                [true, true],
                String(format: "report 0x%02X: the tick's low half is at 30", reportId)
            )
        }
        let first = TritonReportBytes.state(reportId: 0x47, imuTick: 9)
        var padPressure = first
        padPressure.setLe16(30, 10)
        var nextTick = first
        nextTick.setLe16(32, 10)
        XCTAssertEqual(
            motions([first, padPressure, nextTick]).map { $0 != nil },
            [true, false, true],
            "report 0x47: bytes 30-31 are the right pad's pressure and the tick is the two bytes at 32"
        )
    }

    // MARK: - The report shapes

    func testTheBleAndTimestampStateReportsReadTheSameFields() {
        var plain = TritonReportBytes.state(Button.buttonA, imuTick: 1)
        plain.setLe16(10, 1234)
        plain.setLe16(44, 600)
        for reportId: UInt8 in [0x45, 0x47] {
            var other = plain
            other.bytes[0] = reportId
            other.setImuTick(1)
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

    func testAPercentPastFullIsUnknownAsTheOtherClientsReadIt() {
        for level: UInt8 in [101, 180, 255] {
            XCTAssertEqual(
                TritonReportBytes.battery(chargeState: 2, level: level).decode(),
                .battery(PadBattery(level: ProtocolConstants.batteryLevelUnknown, status: .charging)),
                "SDL passes the byte through, and \(level) is no percent the wire carries"
            )
        }
        XCTAssertEqual(TritonReportBytes.battery(chargeState: 2, level: 100).decode(), .battery(PadBattery(level: 100, status: .charging)))
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
