// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import XCTest
@testable import DishCore

/// What a host says, decoded from the fixtures the siblings pin, and what a
/// truncated or unknown packet turns into.
final class MoonlightEventTests: XCTestCase {

    func testRumbleCarriesAnUnusedWordThenThePadAndTwoMotors() {
        XCTAssertEqual(decodeMoonlightEvent(hexData("0b010a00000000000100341200ff")), .rumble(controller: 1, low: 0x1234, high: 0xFF00))
        XCTAssertEqual(decodeMoonlightEvent(hexData("0b010a0000000000010022114433")), .rumble(controller: 1, low: 0x1122, high: 0x3344))
    }

    func testTriggerRumbleMotionRequestAndLamp() {
        XCTAssertEqual(decodeMoonlightEvent(hexData("0055060002000a001400")), .rumbleTriggers(controller: 2, left: 10, right: 20))
        XCTAssertEqual(
            decodeMoonlightEvent(hexData("015505000000640002")),
            .motionRequest(controller: 0, rateHz: 100, type: MoonlightMotionType.gyro)
        )
        XCTAssertEqual(
            decodeMoonlightEvent(hexData("015505000000000001")),
            .motionRequest(controller: 0, rateHz: 0, type: 1),
            "rate 0 is stop"
        )
        XCTAssertEqual(decodeMoonlightEvent(hexData("025505000100102030")), .rgbLed(controller: 1, red: 0x10, green: 0x20, blue: 0x30))
    }

    /// Wolf's 0x0109 and the docs' 0x0100 both end the session.
    func testTerminationUnderEitherTypeWithABigEndianReason() {
        XCTAssertEqual(decodeMoonlightEvent(hexData("0901040080030023")), .termination(reason: 0x8003_0023))
        XCTAssertEqual(decodeMoonlightEvent(hexData("0001040080030023")), .termination(reason: 0x8003_0023))
        XCTAssertEqual(decodeMoonlightEvent(hexData("0901040000000001")), .termination(reason: 1))
    }

    func testAnUnknownTypeIsReportedNotDropped() {
        XCTAssertEqual(decodeMoonlightEvent(hexData("0e01020000ff")), .unknown(type: 0x010E), "HDR_MODE")
        XCTAssertEqual(decodeMoonlightEvent(hexData("00020800" + "0400000000000000")), .unknown(type: 0x0200), "the ping echo")
        XCTAssertEqual(decodeMoonlightEvent(hexData("ffff0000")), .unknown(type: 0xFFFF))
    }

    func testATruncatedBodyIsNilWhateverTheLengthClaims() {
        XCTAssertNil(decodeMoonlightEvent(Data()))
        XCTAssertNil(decodeMoonlightEvent(hexData("0b010a")), "not even a header")
        XCTAssertNil(decodeMoonlightEvent(hexData("0b010a000000000001003412")), "rumble short by two")
        XCTAssertNil(decodeMoonlightEvent(hexData("0055060002000a00")), "triggers short")
        XCTAssertNil(decodeMoonlightEvent(hexData("0155050000006400")), "motion missing its type")
        XCTAssertNil(decodeMoonlightEvent(hexData("0255050001001020")), "lamp missing blue")
        XCTAssertNil(decodeMoonlightEvent(hexData("09010400800300")), "reason short")
    }

    func testTheAdvertisedLengthIsNotWhatBoundsTheRead() {
        XCTAssertEqual(
            decodeMoonlightEvent(hexData("0b01ff00000000000100341200ff")),
            .rumble(controller: 1, low: 0x1234, high: 0xFF00),
            "a lying length still decodes the bytes present"
        )
    }
}
