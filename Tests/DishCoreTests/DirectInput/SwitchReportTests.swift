// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import XCTest

/// The Switch 0x30 report's buttons, triggers and battery for the Pro, the
/// N64 and the SNES pads, ported from dish-android's `usb_parsers_test.cpp`,
/// plus the N64 report captured on a Mac.
final class SwitchReportTests: XCTestCase {

    private func expectEachBitAlone(
        _ kind: SwitchPadKind,
        byte: Int,
        _ cases: [BitCase],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for bitCase in cases {
            var report = SwitchReportBytes()
            report.bytes[byte] = bitCase.mask
            let reading = report.decodeFresh(kind)
            XCTAssertEqual(reading?.report.buttons, bitCase.expected.rawValue, "byte \(byte) bit \(bitCase.mask)", file: file, line: line)
        }
    }

    // MARK: - Pro

    func testProButtonsMapByPhysicalPosition() {
        expectEachBitAlone(.pro, byte: 3, [
            BitCase(mask: 0x01, expected: [.faceX]), BitCase(mask: 0x02, expected: [.faceY]),
            BitCase(mask: 0x04, expected: [.faceA]), BitCase(mask: 0x08, expected: [.faceB]),
            BitCase(mask: 0x40, expected: [.rightShoulder])
        ])
        expectEachBitAlone(.pro, byte: 4, [
            BitCase(mask: 0x01, expected: [.back]), BitCase(mask: 0x02, expected: [.start]),
            BitCase(mask: 0x04, expected: [.rightThumb]), BitCase(mask: 0x08, expected: [.leftThumb])
        ])
        expectEachBitAlone(.pro, byte: 5, [
            BitCase(mask: 0x01, expected: [.dpadDown]), BitCase(mask: 0x02, expected: [.dpadUp]),
            BitCase(mask: 0x04, expected: [.dpadRight]), BitCase(mask: 0x08, expected: [.dpadLeft]),
            BitCase(mask: 0x40, expected: [.leftShoulder])
        ])
    }

    func testProHomeIsGuideAndCaptureHasNoWireBit() {
        expectEachBitAlone(.pro, byte: 4, [BitCase(mask: 0x10, expected: [.guide]), BitCase(mask: 0x20, expected: [])])
    }

    func testProZlAndZrAreDigitalTriggersAndPressNoButton() {
        var report = SwitchReportBytes()
        report.bytes[5] = 0x80
        let zl = report.decodeFresh(.pro)?.report
        XCTAssertEqual(zl?.lt, 255)
        XCTAssertEqual(zl?.rt, 0)
        XCTAssertEqual(zl?.buttons, 0)
        report.bytes[5] = 0
        report.bytes[3] = 0x80
        let zr = report.decodeFresh(.pro)?.report
        XCTAssertEqual(zr?.lt, 0)
        XCTAssertEqual(zr?.rt, 255)
        XCTAssertEqual(zr?.buttons, 0)
        report.bytes[3] = 0
        let released = report.decodeFresh(.pro)?.report
        XCTAssertEqual(released?.lt, 0)
        XCTAssertEqual(released?.rt, 0)
    }

    func testProReadsBothSticks() {
        var report = SwitchReportBytes()
        report.setSticks(lx: SwitchReportBytes.rawMax, ly: SwitchReportBytes.center, rx: 0, ry: SwitchReportBytes.rawMax)
        let reading = report.decodeFresh(.pro)?.report
        XCTAssertEqual(reading?.lx, 32767)
        XCTAssertEqual(reading?.ly, 0)
        XCTAssertEqual(reading?.rx, -32768)
        XCTAssertEqual(reading?.ry, 32767)
    }

    // MARK: - N64

    func testN64ButtonsMapToTheirN64Roles() {
        expectEachBitAlone(.n64, byte: 3, [
            BitCase(mask: 0x04, expected: [.faceB]), BitCase(mask: 0x08, expected: [.faceA]),
            BitCase(mask: 0x40, expected: [.rightShoulder])
        ])
        expectEachBitAlone(.n64, byte: 4, [
            BitCase(mask: 0x02, expected: [.start]), BitCase(mask: 0x10, expected: [.guide]),
            BitCase(mask: 0x20, expected: [.back])
        ])
        expectEachBitAlone(.n64, byte: 5, [
            BitCase(mask: 0x01, expected: [.dpadDown]), BitCase(mask: 0x02, expected: [.dpadUp]),
            BitCase(mask: 0x04, expected: [.dpadRight]), BitCase(mask: 0x08, expected: [.dpadLeft]),
            BitCase(mask: 0x40, expected: [.leftShoulder])
        ])
    }

    func testN64ZAndZrAreTheDigitalTriggers() {
        var report = SwitchReportBytes()
        report.bytes[5] = 0x80
        let z = report.decodeFresh(.n64)?.report
        XCTAssertEqual(z?.lt, 255)
        XCTAssertEqual(z?.rt, 0)
        XCTAssertEqual(z?.buttons, 0)
        report.bytes[5] = 0
        report.bytes[4] = 0x08
        let zr = report.decodeFresh(.n64)?.report
        XCTAssertEqual(zr?.lt, 0)
        XCTAssertEqual(zr?.rt, 255)
        XCTAssertEqual(zr?.buttons, 0)
    }

    func testN64CButtonsRailTheRightStickAndAPairCancels() {
        let cases: [(right: UInt8, shared: UInt8, rx: Int16, ry: Int16)] = [
            (0x01, 0x00, 0, 32767),
            (0x80, 0x00, 0, -32767),
            (0x02, 0x00, -32767, 0),
            (0x00, 0x01, 32767, 0),
            (0x81, 0x00, 0, 0),
            (0x02, 0x01, 0, 0)
        ]
        for c in cases {
            var report = SwitchReportBytes()
            report.bytes[3] = c.right
            report.bytes[4] = c.shared
            let state = report.decodeFresh(.n64)?.report
            XCTAssertEqual(state?.rx, c.rx, "right \(c.right) shared \(c.shared)")
            XCTAssertEqual(state?.ry, c.ry, "right \(c.right) shared \(c.shared)")
            XCTAssertEqual(state?.buttons, 0, "a C button is a stick, not a bit")
            XCTAssertEqual(state?.rt, 0, "C-down's bit is not a trigger")
        }
    }

    func testN64ReadsOnlyTheLeftStickAndHasNoMotion() {
        var report = SwitchReportBytes(length: 49)
        report.setSticks(
            lx: SwitchReportBytes.rawMax,
            ly: SwitchReportBytes.center,
            rx: SwitchReportBytes.rawMax,
            ry: SwitchReportBytes.rawMax
        )
        report.bytes[13] = 0x34
        report.bytes[14] = 0x12
        let reading = report.decodeFresh(.n64)
        XCTAssertGreaterThan(reading?.report.lx ?? 0, 0)
        XCTAssertEqual(reading?.report.ly, 0)
        XCTAssertEqual(reading?.report.rx, 0)
        XCTAssertEqual(reading?.report.ry, 0)
        XCTAssertNil(reading?.motion)
    }

    /// `30 6b 91 00 80 00 01 c8 7e 00 00 00 08 00`, idle, through IOHIDManager
    /// on Emir's Mac: the 0x80 in byte 4 is no N64 input, both sticks rest
    /// inside the dead zone, and byte 2 says full and charging.
    func testTheIdleN64ReportCapturedOnAMacDecodesToNothingHeld() {
        let idle = SwitchReportBytes(raw: [0x30, 0x6B, 0x91, 0x00, 0x80, 0x00, 0x01, 0xC8, 0x7E, 0x00, 0x00, 0x00, 0x08, 0x00])
        let reading = idle.decodeFresh(.n64)
        XCTAssertEqual(reading?.report, GamepadReport.released)
        XCTAssertNil(reading?.motion)
        XCTAssertEqual(reading?.battery, PadBattery(level: 100, status: .charging))
    }

    // MARK: - SNES

    func testSnesReadsProButtonsAndTriggersWithoutSticksOrMotion() {
        var report = SwitchReportBytes(length: 49)
        report.bytes[3] = 0x08 | 0x80
        report.bytes[4] = 0x02
        report.bytes[5] = 0x02
        report.setLe16(21, 4000)
        let reading = report.decodeFresh(.snes)
        XCTAssertEqual(reading?.report, GamepadReport(buttons: WireButtonWord([.faceB, .start, .dpadUp]).rawValue, rt: 255))
        XCTAssertNil(reading?.motion, "the SNES pad has no IMU")
    }

    // MARK: - Framing

    func testAWrongReportIdOrAShortReportIsRejectedForEveryKind() {
        for kind in [SwitchPadKind.pro, .n64, .snes] {
            var wrongId = SwitchReportBytes()
            wrongId.bytes[0] = 0x21
            XCTAssertNil(wrongId.decodeFresh(kind))
            XCTAssertNil(SwitchReportBytes(length: 11).decodeFresh(kind))
            XCTAssertNotNil(SwitchReportBytes(length: 12).decodeFresh(kind), "twelve bytes is the minimum")
        }
    }

    // MARK: - Battery

    func testTheBatteryReadsTheFiveStepsTheChargingBitAndTheHostBit() {
        XCTAssertEqual(decodeSwitchBattery(0x40), PadBattery(level: 50, status: .discharging), "step 2 on battery")
        XCTAssertEqual(decodeSwitchBattery(0x71), PadBattery(level: 75, status: .charging), "step 3, host-powered, charging")
        XCTAssertEqual(decodeSwitchBattery(0x81), PadBattery(level: 100, status: .full), "full on the cable, not charging")
        XCTAssertEqual(decodeSwitchBattery(0x80), PadBattery(level: 100, status: .discharging), "full on battery")
        XCTAssertEqual(decodeSwitchBattery(0x01), PadBattery(level: 5, status: .discharging), "host power below full is not full")
        XCTAssertEqual(decodeSwitchBattery(0x20), PadBattery(level: 25, status: .discharging))
        XCTAssertEqual(decodeSwitchBattery(0x00), PadBattery(level: 5, status: .discharging), "empty")
        XCTAssertEqual(decodeSwitchBattery(0xA0).level, ProtocolConstants.batteryLevelUnknown, "a step the pad never reports")
    }

    func testEveryKindReadsTheBatteryByte() {
        for kind in [SwitchPadKind.pro, .n64, .snes] {
            var report = SwitchReportBytes()
            report.bytes[2] = 0x80
            XCTAssertEqual(report.decodeFresh(kind)?.battery, PadBattery(level: 100, status: .discharging))
        }
    }
}
