// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import XCTest
@testable import Dish

/// Coverage for `SatelliteClient.parseLightbarPayload` — the pure decoder
/// for the satellite → dish `MSG_LIGHTBAR` (0x000D) payload, the dedicated
/// Task 1.4 stream. Same pattern as `SatelliteClientRumbleTests`.
final class SatelliteClientLightbarTests: XCTestCase {

    func testParseLightbarPayloadHappyPath() {
        let p: [UInt8] = [/*ctrlIdx=*/3, /*r=*/0xDE, /*g=*/0xAD, /*b=*/0xBE]
        let lm = SatelliteClient.parseLightbarPayload(p)
        XCTAssertNotNil(lm)
        XCTAssertEqual(lm?.controllerIndex, 3)
        XCTAssertEqual(lm?.r, 0xDE)
        XCTAssertEqual(lm?.g, 0xAD)
        XCTAssertEqual(lm?.b, 0xBE)
    }

    func testParseLightbarPayloadRejectsShort() {
        XCTAssertNil(SatelliteClient.parseLightbarPayload([0, 0, 0]))
        XCTAssertNil(SatelliteClient.parseLightbarPayload([]))
    }

    func testParseLightbarPayloadToleratesTrailingBytes() {
        // Future protocol extensions may append fields. The decoder should
        // accept the leading 4 bytes and ignore the rest.
        var p: [UInt8] = Array(repeating: 0, count: 12)
        p[0] = 7
        p[1] = 0x11
        p[2] = 0x22
        p[3] = 0x33
        p[8] = 0xFF // pretend-future field
        let lm = SatelliteClient.parseLightbarPayload(p)
        XCTAssertNotNil(lm)
        XCTAssertEqual(lm?.controllerIndex, 7)
        XCTAssertEqual(lm?.r, 0x11)
        XCTAssertEqual(lm?.g, 0x22)
        XCTAssertEqual(lm?.b, 0x33)
    }

    func testParseLightbarPayloadAllZero() {
        let lm = SatelliteClient.parseLightbarPayload([0, 0, 0, 0])
        XCTAssertNotNil(lm)
        XCTAssertEqual(lm?.r, 0)
        XCTAssertEqual(lm?.g, 0)
        XCTAssertEqual(lm?.b, 0)
    }

    func testParseLightbarPayloadAllMax() {
        let lm = SatelliteClient.parseLightbarPayload([0xFF, 0xFF, 0xFF, 0xFF])
        XCTAssertNotNil(lm)
        XCTAssertEqual(lm?.controllerIndex, 0xFF)
        XCTAssertEqual(lm?.r, 0xFF)
        XCTAssertEqual(lm?.g, 0xFF)
        XCTAssertEqual(lm?.b, 0xFF)
    }

    func testMsgLightbarConstantPinsWireByte() {
        XCTAssertEqual(SatelliteClient.msgLightbar, 0x000D)
    }
}
