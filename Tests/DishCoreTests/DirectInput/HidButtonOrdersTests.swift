// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import XCTest

/// The four button orders over real devices' descriptors, ported from the
/// desktops' `test_usb_hid_layout.cpp` (Switch order) and
/// `test_usb_hid_layout_orders.cpp` (8BitDo, PlayStation Classic).
final class HidButtonOrdersTests: XCTestCase {

    private let dpad: UInt16 = WireButtonWord([.dpadUp, .dpadDown, .dpadLeft, .dpadRight]).rawValue

    private func layout(_ descriptor: [UInt8], _ order: HidButtonOrder) throws -> HidGamepadLayout {
        try XCTUnwrap(HidGamepadLayout.parse(descriptor: descriptor, order: order))
    }

    private func faceoff(_ low: UInt8, _ high: UInt8, hat: UInt8 = 0x08, x: UInt8 = 0x7F) -> [UInt8] {
        [low, high, hat, x, 0x7F, 0x7F, 0x7F]
    }

    /// Buttons 1-8 in byte 0, 9-15 in byte 1, the hat (0x0F centred), the
    /// four axes at 0x7F, Accelerator and Brake.
    private func m30(_ low: UInt8, _ high: UInt8, hat: UInt8 = 0x0F) -> [UInt8] {
        [low, high, hat, 0x7F, 0x7F, 0x7F, 0x7F, 0x00, 0x00]
    }

    // MARK: - Switch order (PDP wired Switch pads)

    func testWithoutTheSwitchOrderTheFaceoffPadIsScrambled() throws {
        let western = try layout(HidDescriptors.switchOrder, .western)
        XCTAssertEqual(decodeHid(western, faceoff(0x04, 0x00))?.buttons, WireButtonWord([.faceX]).rawValue, "physical A lands on X")
        let zl = try XCTUnwrap(decodeHid(western, faceoff(0x40, 0x00)))
        XCTAssertEqual(zl.buttons, WireButtonWord([.back]).rawValue, "ZL lands on Back")
        XCTAssertEqual(zl.lt, 0)
        XCTAssertEqual(decodeHid(western, faceoff(0x00, 0x38))?.buttons, 0, "R3, Home and Capture vanish")
    }

    func testSwitchOrderFaceButtonsRemapByPosition() throws {
        let switchOrder = try layout(HidDescriptors.switchOrder, .nintendoSwitch)
        let cases: [(UInt8, WireButton)] = [(0x01, .faceX), (0x02, .faceA), (0x04, .faceB), (0x08, .faceY)]
        for (bit, button) in cases {
            XCTAssertEqual(decodeHid(switchOrder, faceoff(bit, 0x00))?.buttons, WireButtonWord([button]).rawValue, "bit \(bit)")
        }
    }

    func testSwitchOrderBumpersMapAndZlZrDriveTheTriggers() throws {
        let switchOrder = try layout(HidDescriptors.switchOrder, .nintendoSwitch)
        let bumpers = try XCTUnwrap(decodeHid(switchOrder, faceoff(0x30, 0x00)))
        XCTAssertEqual(bumpers.buttons, WireButtonWord([.leftShoulder, .rightShoulder]).rawValue)
        XCTAssertEqual([bumpers.lt, bumpers.rt], [0, 0])
        let triggers = try XCTUnwrap(decodeHid(switchOrder, faceoff(0xC0, 0x00)))
        XCTAssertEqual(triggers.buttons, 0)
        XCTAssertEqual([triggers.lt, triggers.rt], [255, 255])
        let released = try XCTUnwrap(decodeHid(switchOrder, faceoff(0x00, 0x00)))
        XCTAssertEqual([released.lt, released.rt], [0, 0])
    }

    func testSwitchOrderUpperRowMapsMinusPlusTheClicksAndHome() throws {
        let switchOrder = try layout(HidDescriptors.switchOrder, .nintendoSwitch)
        let cases: [(UInt8, WireButtonWord)] = [
            (0x01, [.back]), (0x02, [.start]), (0x04, [.leftThumb]), (0x08, [.rightThumb]), (0x10, [.guide]), (0x20, [])
        ]
        for (bit, word) in cases {
            XCTAssertEqual(decodeHid(switchOrder, faceoff(0x00, bit))?.buttons, word.rawValue, "bit \(bit); Capture has no XUSB bit")
        }
    }

    func testSwitchOrderLeavesTheHatAndSticksAlone() throws {
        let switchOrder = try layout(HidDescriptors.switchOrder, .nintendoSwitch)
        let east = try XCTUnwrap(decodeHid(switchOrder, faceoff(0x00, 0x00, hat: 0x02, x: 0xFF)))
        XCTAssertEqual(east.buttons & dpad, WireButtonWord([.dpadRight]).rawValue)
        XCTAssertGreaterThan(east.lx, 30000)
        let neutral = try XCTUnwrap(decodeHid(switchOrder, faceoff(0x00, 0x00)))
        XCTAssertEqual(neutral.buttons & dpad, 0)
        XCTAssertEqual(neutral.lx, 0)
    }

    func testSwitchOrderDecodesACombinedReport() throws {
        let switchOrder = try layout(HidDescriptors.switchOrder, .nintendoSwitch)
        let state = try XCTUnwrap(decodeHid(switchOrder, faceoff(0x44, 0x02, hat: 0x04, x: 0xFF)))
        XCTAssertEqual(state.buttons, WireButtonWord([.faceB, .start, .dpadDown]).rawValue)
        XCTAssertEqual(state.lt, 255)
        XCTAssertEqual(state.rt, 0)
        XCTAssertGreaterThan(state.lx, 30000)
    }

    // MARK: - 8BitDo order (M30, adapters)

    func testM30FaceButtonsKeepTheirLettersAndHeartIsGuide() throws {
        let order = try layout(HidDescriptors.m30, .eightBitDo)
        let cases: [(UInt8, UInt8, WireButtonWord)] = [
            (0x01, 0x00, [.faceA]), (0x02, 0x00, [.faceB]), (0x04, 0x00, [.guide]), (0x08, 0x00, [.faceX]),
            (0x10, 0x00, [.faceY]), (0x20, 0x00, []), (0x00, 0x10, [.guide])
        ]
        for (low, high, word) in cases {
            XCTAssertEqual(decodeHid(order, m30(low, high))?.buttons, word.rawValue, "\(low) \(high)")
        }
    }

    func testM30ZAndCAreTheShouldersSelectIsBackAndStartIsStart() throws {
        let order = try layout(HidDescriptors.m30, .eightBitDo)
        let cases: [(UInt8, UInt8, WireButton)] = [
            (0x40, 0x00, .leftShoulder), (0x80, 0x00, .rightShoulder), (0x00, 0x04, .back),
            (0x00, 0x08, .start), (0x00, 0x20, .leftThumb), (0x00, 0x40, .rightThumb)
        ]
        for (low, high, button) in cases {
            XCTAssertEqual(decodeHid(order, m30(low, high))?.buttons, WireButtonWord([button]).rawValue, "\(low) \(high)")
        }
    }

    func testM30LAndREachDriveOneTriggerAndNothingElse() throws {
        let order = try layout(HidDescriptors.m30, .eightBitDo)
        let left = try XCTUnwrap(decodeHid(order, m30(0x00, 0x01)))
        XCTAssertEqual([left.lt, left.rt], [255, 0])
        XCTAssertEqual(left.buttons, 0)
        let right = try XCTUnwrap(decodeHid(order, m30(0x00, 0x02)))
        XCTAssertEqual([right.lt, right.rt], [0, 255])
        XCTAssertEqual(right.buttons, 0)
    }

    func testM30AcceleratorAndBrakeOnlyEchoTheDigitalTriggers() throws {
        let order = try layout(HidDescriptors.m30, .eightBitDo)
        let analogOnly = try XCTUnwrap(decodeHid(order, [0x00, 0x00, 0x0F, 0x7F, 0x7F, 0x7F, 0x7F, 0xFF, 0xFF]))
        XCTAssertEqual([analogOnly.lt, analogOnly.rt], [0, 0])
    }

    func testM30DpadArrivesAsTheHatOrAsTheLeftStickByMode() throws {
        let order = try layout(HidDescriptors.m30, .eightBitDo)
        XCTAssertEqual((decodeHid(order, m30(0x00, 0x00, hat: 0x00))?.buttons ?? 0) & dpad, WireButtonWord([.dpadUp]).rawValue)
        XCTAssertEqual((decodeHid(order, m30(0x00, 0x00, hat: 0x06))?.buttons ?? 0) & dpad, WireButtonWord([.dpadLeft]).rawValue)
        let stickLeft = try XCTUnwrap(decodeHid(order, [0x00, 0x00, 0x0F, 0x00, 0x7F, 0x7F, 0x7F, 0x00, 0x00]))
        XCTAssertLessThan(stickLeft.lx, -32000)
        XCTAssertEqual(stickLeft.buttons & dpad, 0)
    }

    func testTheWesternOrderScramblesTheM30WhichTheEightBitDoOrderFixes() throws {
        let western = try layout(HidDescriptors.m30, .western)
        XCTAssertEqual(decodeHid(western, m30(0x00, 0x08))?.buttons, 0, "Start is lost")
        XCTAssertEqual(decodeHid(western, m30(0x04, 0x00))?.buttons, WireButtonWord([.faceX]).rawValue, "Heart lands on X")
    }

    func testTheAdapter2DecodesItsCapturedReportsBehindReportId1() throws {
        let order = try layout(HidDescriptors.adapter2, .eightBitDo)
        let idle = try XCTUnwrap(decodeHid(order, [0x01, 0x00, 0x00, 0x0F, 0x7C, 0x82, 0x7F, 0x82, 0x00, 0x00]))
        XCTAssertEqual(idle.buttons, 0)
        XCTAssertEqual([idle.lt, idle.rt], [0, 0])
        XCTAssertTrue((-2000 ..< 0).contains(idle.lx), "a resting stick a hair left of centre")
        let viewLeft = decodeHid(order, [0x01, 0x00, 0x04, 0x06, 0x7C, 0x82, 0x7F, 0x81, 0x00, 0x00])
        XCTAssertEqual(viewLeft?.buttons, WireButtonWord([.back, .dpadLeft]).rawValue)
        let right = decodeHid(order, [0x01, 0x00, 0x00, 0x02, 0x7C, 0x82, 0x7F, 0x82, 0x00, 0x00])
        XCTAssertEqual(right?.buttons, WireButtonWord([.dpadRight]).rawValue)
        XCTAssertNil(decodeHid(order, [0x02, 0x00, 0x00, 0x0F, 0x7C, 0x82, 0x7F, 0x82, 0x00, 0x00]), "the vendor report")
    }

    // MARK: - PlayStation Classic order

    func testPlayStationClassicButtonsMapByPosition() throws {
        let order = try layout(HidDescriptors.psClassic, .playStationClassic)
        let cases: [(UInt8, UInt8, WireButton)] = [
            (0x01, 0x14, .faceY), (0x02, 0x14, .faceB), (0x04, 0x14, .faceA), (0x08, 0x14, .faceX),
            (0x40, 0x14, .leftShoulder), (0x80, 0x14, .rightShoulder), (0x00, 0x15, .back), (0x00, 0x16, .start)
        ]
        for (low, high, button) in cases {
            XCTAssertEqual(decodeHid(order, [low, high])?.buttons, WireButtonWord([button]).rawValue, "\(low) \(high)")
        }
        let l2 = try XCTUnwrap(decodeHid(order, [0x10, 0x14]))
        XCTAssertEqual(l2.lt, 255)
        XCTAssertEqual(l2.buttons, 0)
        let r2 = try XCTUnwrap(decodeHid(order, [0x20, 0x14]))
        XCTAssertEqual(r2.rt, 255)
        XCTAssertEqual(r2.buttons, 0)
    }

    // MARK: - Western order

    func testTheWesternOrderIsDirectInputsAndHasNoDigitalTriggers() throws {
        let gamepad = try layout(HidDescriptors.gamepad, .western)
        let expected: [WireButton] = [.faceA, .faceB, .faceX, .faceY, .leftShoulder, .rightShoulder, .back, .start, .leftThumb, .rightThumb]
        for (index, button) in expected.enumerated() {
            let word = UInt16(1) << UInt16(index)
            let report: [UInt8] = [0x7F, 0x7F, 0x7F, 0x7F, 0x08, UInt8(word & 0xFF), UInt8(word >> 8)]
            let state = decodeHid(gamepad, report)
            XCTAssertEqual(state?.buttons, WireButtonWord([button]).rawValue, "button \(index + 1)")
            XCTAssertEqual(state?.lt, 0)
        }
    }

    func testAWesternEleventhButtonIsGuideAndLaterButtonsHaveNoBit() throws {
        let buttons: [UInt8] = [0x05, 0x09, 0x19, 0x01, 0x29, 0x10, 0x15, 0x00, 0x25, 0x01, 0x75, 0x01, 0x95, 0x10, 0x81, 0x02]
        let western = try layout(buttons, .western)
        XCTAssertEqual(decodeHid(western, [0x00, 0x04])?.buttons, WireButtonWord([.guide]).rawValue)
        XCTAssertEqual(decodeHid(western, [0x00, 0xF8])?.buttons, 0)
    }
}
