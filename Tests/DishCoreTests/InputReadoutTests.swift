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
