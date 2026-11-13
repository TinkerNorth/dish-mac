// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import XCTest
@testable import DishCore

/// The inspector reads the wire's units the way the other clients do.
final class InputReadoutTests: XCTestCase {

    func testTheButtonTableIsTheXusbWordInBitOrder() {
        XCTAssertEqual(WireButton.allCases.map(\.bit), [
            0x0001, 0x0002, 0x0004, 0x0008, 0x0010, 0x0020, 0x0040, 0x0080,
            0x0100, 0x0200, 0x0400, 0x0800, 0x1000, 0x2000, 0x4000, 0x8000
        ])
        XCTAssertEqual(WireButton.micMute.bit, MicMute.buttonBit, "the mic-mute button is the word's one unassigned slot")
    }

    func testPressedButtonsReadTheWordInWireOrder() {
        XCTAssertEqual(pressedButtons(0), [])
        XCTAssertEqual(pressedButtons(0x1000 | 0x0001 | 0x0800), [.dpadUp, .micMute, .faceA])
        XCTAssertEqual(pressedButtons(0xFFFF).count, 16)
    }

    func testTheExtendedButtonTableIsTheProtocolFourWordInBitOrder() {
        let protocolBits: [(ExtendedButton, UInt32)] = [
            (.rightPaddle1, ProtocolConstants.extButtonRightPaddle1),
            (.leftPaddle1, ProtocolConstants.extButtonLeftPaddle1),
            (.rightPaddle2, ProtocolConstants.extButtonRightPaddle2),
            (.leftPaddle2, ProtocolConstants.extButtonLeftPaddle2),
            (.misc1, ProtocolConstants.extButtonMisc1),
            (.leftPadClick, ProtocolConstants.extButtonLeftPadClick),
            (.rightPadClick, ProtocolConstants.extButtonRightPadClick),
            (.leftTriggerClick, ProtocolConstants.extButtonLeftTriggerClick),
            (.rightTriggerClick, ProtocolConstants.extButtonRightTriggerClick),
            (.leftStickTouch, ProtocolConstants.extButtonLeftStickTouch),
            (.rightStickTouch, ProtocolConstants.extButtonRightStickTouch),
            (.leftGripTouch, ProtocolConstants.extButtonLeftGripTouch),
            (.rightGripTouch, ProtocolConstants.extButtonRightGripTouch)
        ]
        let bits = ExtendedButton.allCases.map(\.bit)
        XCTAssertEqual(ExtendedButton.allCases, protocolBits.map(\.0))
        XCTAssertEqual(bits, protocolBits.map(\.1))
        XCTAssertEqual(bits, ExtendedButton.allCases.indices.map { UInt32(1) << $0 }, "one bit each, in wire order")
        XCTAssertEqual(bits.reduce(0, |), ProtocolConstants.extButtonsKnownMask, "every bit the wire carries")
    }

    func testPressedExtendedButtonsReadTheWordInWireOrderAndSkipBitsTheWireDoesNotCarry() {
        let beyondTheWord = ~ProtocolConstants.extButtonsKnownMask
        let held = ProtocolConstants.extButtonMisc1 | ProtocolConstants.extButtonLeftPaddle1 | beyondTheWord
        XCTAssertEqual(pressedExtendedButtons(0), [])
        XCTAssertEqual(pressedExtendedButtons(held), [.leftPaddle1, .misc1])
        XCTAssertEqual(pressedExtendedButtons(.max), ExtendedButton.allCases)
    }

    func testSticksTriggersMotionAndTouchReadInHumanUnits() {
        XCTAssertEqual(InputReadout.stickFraction(16384), 0.5)
        XCTAssertEqual(InputReadout.stickFraction(-32768), -1)
        XCTAssertEqual(InputReadout.stickSample(x: 32767, y: 0).x, 0.99997, accuracy: 0.0001)
        XCTAssertEqual(InputReadout.triggerFraction(255), 1)
        XCTAssertEqual(InputReadout.triggerFraction(0), 0)
        XCTAssertEqual(InputReadout.gyroDegreesPerSecond(32767), 2000)
        XCTAssertEqual(InputReadout.gyroDegreesPerSecond(-16384), -1000.03, accuracy: 0.1)
        XCTAssertEqual(InputReadout.accelG(32767), 4)
        XCTAssertEqual(InputReadout.touchFraction(-32768), 0)
        XCTAssertEqual(InputReadout.touchFraction(32767), 1)
        XCTAssertEqual(InputReadout.touchFraction(0), 0.5, accuracy: 0.0001)
    }
}
