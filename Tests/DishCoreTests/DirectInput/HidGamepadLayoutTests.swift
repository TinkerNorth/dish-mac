// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import XCTest

/// Decoding a report over a parsed layout: sticks, the saturating Y
/// inversion, triggers, the hat, three-state axes and report ids, ported
/// from the desktops' `test_usb_hid_layout*.cpp`.
final class HidGamepadLayoutTests: XCTestCase {

    private let dpad: UInt16 = WireButtonWord([.dpadUp, .dpadDown, .dpadLeft, .dpadRight]).rawValue

    private func layout(_ descriptor: [UInt8], order: HidButtonOrder = .western) throws -> HidGamepadLayout {
        try XCTUnwrap(HidGamepadLayout.parse(descriptor: descriptor, order: order))
    }

    func testSticksButtonsAndTheHatDecode() throws {
        let gamepad = try layout(HidDescriptors.gamepad)
        let state = try XCTUnwrap(decodeHid(gamepad, [0xFF, 0x7F, 0x7F, 0x7F, 0x02, 0x03, 0x00]))
        XCTAssertEqual(state.lx, 32767, "X full right")
        XCTAssertEqual(state.buttons, WireButtonWord([.faceA, .faceB, .dpadRight]).rawValue, "buttons 1 and 2, hat east")
    }

    /// HID's Y is down-positive; the wire's is up-positive.
    func testHidYIsInvertedOntoTheUpPositiveWire() throws {
        let gamepad = try layout(HidDescriptors.gamepad)
        let up = try XCTUnwrap(decodeHid(gamepad, [0x7F, 0x00, 0x7F, 0x00, 0x08, 0x00, 0x00]))
        XCTAssertEqual(up.ly, 32767, "Y at its minimum is pushed up")
        XCTAssertEqual(up.ry, 32767, "Rz at its minimum is pushed up")
        let down = try XCTUnwrap(decodeHid(gamepad, [0x7F, 0xFF, 0x7F, 0xFF, 0x08, 0x00, 0x00]))
        XCTAssertEqual(down.ly, -32767, "the clamped rail, inverted")
        XCTAssertEqual(down.ry, -32767)
    }

    func testInvertingTheNegativeRailSaturatesInsteadOfTrapping() throws {
        let signed = try layout(HidDescriptors.signedOneByte)
        let state = try XCTUnwrap(decodeHid(signed, [0x00, 0x80, 0x00]))
        XCTAssertEqual(state.ly, Int16.max, "-128 over -127...127 scales past Int16.min, and its negation saturates")
    }

    func testAReportIdIsRequiredAndTheIdByteIsNotPayload() throws {
        let withId = try layout(HidDescriptors.reportId)
        let good = try XCTUnwrap(decodeHid(withId, [0x03, 0xFF, 0x80]))
        XCTAssertEqual(good.lx, 32767)
        XCTAssertNil(decodeHid(withId, [0x05, 0xFF, 0x80]), "another report's id")
        XCTAssertNil(decodeHid(withId, []), "no id byte at all")
    }

    func testAShortReportReadsTheMissingBitsAsZero() throws {
        let gamepad = try layout(HidDescriptors.gamepad)
        let state = try XCTUnwrap(decodeHid(gamepad, [0xFF]))
        XCTAssertEqual(state.lx, 32767)
        XCTAssertEqual(state.ly, 32767, "a missing Y reads as raw 0, its minimum")
        XCTAssertEqual(state.buttons & dpad, WireButtonWord([.dpadUp]).rawValue, "a missing hat reads as raw 0, north")
    }

    func testAWideAxisScalesWithoutOverflow() throws {
        let wide = try layout(HidDescriptors.wideAxis)
        XCTAssertEqual(decodeHid(wide, [0xFF, 0xFF, 0xFF, 0x7F])?.lx, 32767)
    }

    func testAFullRangeSigned32BitAxisScalesWithoutOverflowing() throws {
        let signed = try layout(HidDescriptors.signed32Axes)
        XCTAssertEqual(decodeHid(signed, [0xFF, 0xFF, 0xFF, 0x7F, 0, 0, 0, 0, 0])?.lx, 32767)
        XCTAssertEqual(decodeHid(signed, [0x00, 0x00, 0x00, 0x80, 0, 0, 0, 0, 0])?.lx, -32767)
        XCTAssertEqual(decodeHid(signed, [0, 0, 0, 0, 0, 0, 0, 0, 0])?.lx, 0)
    }

    func testAFullRangeSigned32BitTriggerScalesWithoutOverflowing() throws {
        let signed = try layout(HidDescriptors.signed32Triggers)
        XCTAssertEqual(decodeHid(signed, [0xFF, 0xFF, 0xFF, 0x7F, 0, 0, 0, 0, 0])?.lt, 255)
        XCTAssertEqual(decodeHid(signed, [0, 0, 0, 0, 0, 0, 0, 0, 0])?.lt, 127)
        XCTAssertEqual(decodeHid(signed, [0x00, 0x00, 0x00, 0x80, 0, 0, 0, 0, 0])?.lt, 0)
    }

    func testAOneByteMaximumOf0xFFScalesOverTheFullByte() throws {
        let unsigned = try layout(HidDescriptors.oneByteMaximum)
        XCTAssertEqual(decodeHid(unsigned, [0xFF, 0x7F, 0x00])?.lx, 32767)
        XCTAssertEqual(decodeHid(unsigned, [0x00, 0x7F, 0x00])?.lx, -32767)
        XCTAssertEqual(decodeHid(unsigned, [0x7F, 0x7F, 0x00])?.lx, 0)
    }

    func testASignedOneByteAxisKeepsItsSign() throws {
        let signed = try layout(HidDescriptors.signedOneByte)
        XCTAssertEqual(decodeHid(signed, [0x7F, 0x00, 0x00])?.lx, 32767)
        XCTAssertEqual(decodeHid(signed, [0x81, 0x00, 0x00])?.lx, -32767)
    }

    func testANarrowHatRejectsItsOutOfRangeNull() throws {
        let hat = try layout(HidDescriptors.narrowHat)
        XCTAssertEqual(decodeHid(hat, [0x02])?.buttons, WireButtonWord([.dpadRight]).rawValue)
        XCTAssertEqual(decodeHid(hat, [0x04])?.buttons, 0, "4 is outside 0...3")
    }

    func testEveryHatDirectionFoldsIntoTheDpadAndTheNullIsCentred() throws {
        let gamepad = try layout(HidDescriptors.gamepad)
        let expected: [WireButtonWord] = [
            [.dpadUp], [.dpadUp, .dpadRight], [.dpadRight], [.dpadDown, .dpadRight],
            [.dpadDown], [.dpadDown, .dpadLeft], [.dpadLeft], [.dpadUp, .dpadLeft], [], []
        ]
        for (hat, word) in expected.enumerated() {
            let state = decodeHid(gamepad, [0x7F, 0x7F, 0x7F, 0x7F, UInt8(hat), 0x00, 0x00])
            XCTAssertEqual(state?.buttons, word.rawValue, "hat \(hat)")
        }
    }

    func testAThreeStateAxisIsADirectionPadNotAStick() throws {
        let classic = try layout(HidDescriptors.psClassic, order: .playStationClassic)
        let centred = try XCTUnwrap(decodeHid(classic, [0x00, 0x14]))
        XCTAssertEqual(centred.buttons & dpad, 0)
        XCTAssertEqual(centred.lx, 0)
        XCTAssertEqual(centred.ly, 0)
        XCTAssertEqual(decodeHid(classic, [0x00, 0x10])?.buttons, WireButtonWord([.dpadLeft]).rawValue, "X = 0")
        XCTAssertEqual(decodeHid(classic, [0x00, 0x18])?.buttons, WireButtonWord([.dpadRight]).rawValue, "X = 2")
        XCTAssertEqual(decodeHid(classic, [0x00, 0x04])?.buttons, WireButtonWord([.dpadUp]).rawValue, "Y = 0")
        XCTAssertEqual(decodeHid(classic, [0x00, 0x24])?.buttons, WireButtonWord([.dpadDown]).rawValue, "Y = 2")
        XCTAssertEqual(decodeHid(classic, [0x00, 0x20])?.buttons, WireButtonWord([.dpadDown, .dpadLeft]).rawValue)
        XCTAssertEqual(decodeHid(classic, [0x00, 0x18])?.lx, 0)
        XCTAssertEqual(decodeHid(classic, [0x00, 0x1C])?.buttons, 0, "3 is no direction")
    }

    func testOnlyTheLeftStickReadsAsADirectionPad() throws {
        let threeStateZ: [UInt8] = [
            0x05, 0x01, 0x09, 0x32, 0x15, 0x00, 0x25, 0x02, 0x75, 0x02, 0x95, 0x01, 0x81, 0x02,
            0x75, 0x06, 0x95, 0x01, 0x81, 0x01, 0x05, 0x09, 0x19, 0x01, 0x29, 0x01, 0x25, 0x01, 0x75, 0x01,
            0x95, 0x01, 0x81, 0x02
        ]
        let layout = try layout(threeStateZ)
        let state = try XCTUnwrap(decodeHid(layout, [0x02, 0x00]))
        XCTAssertEqual(state.rx, 32767, "a three-state Z is still a stick")
        XCTAssertEqual(state.buttons, 0)
    }

    func testAnAnalogTriggerIsReadWhenTheOrderHasNoDigitalOne() throws {
        let m30 = try layout(HidDescriptors.m30)
        let state = try XCTUnwrap(decodeHid(m30, [0x00, 0x00, 0x0F, 0x7F, 0x7F, 0x7F, 0x7F, 0xFF, 0x80]))
        XCTAssertEqual(state.rt, 255, "Accelerator")
        XCTAssertEqual(state.lt, 128, "Brake")
    }

    func testADegenerateRangeReadsCentreAndUnpulled() throws {
        let flat: [UInt8] = [0x05, 0x01, 0x09, 0x30, 0x09, 0x33, 0x15, 0x05, 0x25, 0x05, 0x75, 0x08, 0x95, 0x02, 0x81, 0x02]
        let layout = try layout(flat)
        let state = try XCTUnwrap(decodeHid(layout, [0xFF, 0xFF]))
        XCTAssertEqual(state.lx, 0)
        XCTAssertEqual(state.lt, 0)
    }
}
