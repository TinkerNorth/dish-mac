// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import XCTest
@testable import Dish

/// Unit tests for the touchpad encoder and lightbar parser added in
/// `SatelliteClient` (Tier 1 Tasks 1.3 + 1.4). The wire format these
/// produce must match `satellite/src/core/types.h::TouchpadReport` and the
/// `MSG_LIGHTBAR` payload (`ctrlIdx + r + g + b`) byte-for-byte — these
/// tests pin both directions.
final class TouchpadLightbarTests: XCTestCase {

    // MARK: - encodeTouchpadPayload

    func testTouchpadPayloadIs12Bytes() {
        let p = SatelliteClient.encodeTouchpadPayload(
            controllerIndex: 0,
            finger0Active: false, finger0Id: 0, finger0X: 0, finger0Y: 0,
            finger1Active: false, finger1Id: 0, finger1X: 0, finger1Y: 0,
            buttonPressed: false
        )
        XCTAssertEqual(p.count, 12)
    }

    func testTouchpadFlagsBitsMapToBooleans() {
        // No finger / no button → flags = 0
        var p = SatelliteClient.encodeTouchpadPayload(
            controllerIndex: 0,
            finger0Active: false, finger0Id: 0, finger0X: 0, finger0Y: 0,
            finger1Active: false, finger1Id: 0, finger1X: 0, finger1Y: 0,
            buttonPressed: false
        )
        XCTAssertEqual(p[1], 0x00)

        // finger0 active only → bit 0
        p = SatelliteClient.encodeTouchpadPayload(
            controllerIndex: 0,
            finger0Active: true, finger0Id: 0, finger0X: 0, finger0Y: 0,
            finger1Active: false, finger1Id: 0, finger1X: 0, finger1Y: 0,
            buttonPressed: false
        )
        XCTAssertEqual(p[1], 0x01)

        // finger1 active only → bit 1
        p = SatelliteClient.encodeTouchpadPayload(
            controllerIndex: 0,
            finger0Active: false, finger0Id: 0, finger0X: 0, finger0Y: 0,
            finger1Active: true, finger1Id: 0, finger1X: 0, finger1Y: 0,
            buttonPressed: false
        )
        XCTAssertEqual(p[1], 0x02)

        // button only → bit 2
        p = SatelliteClient.encodeTouchpadPayload(
            controllerIndex: 0,
            finger0Active: false, finger0Id: 0, finger0X: 0, finger0Y: 0,
            finger1Active: false, finger1Id: 0, finger1X: 0, finger1Y: 0,
            buttonPressed: true
        )
        XCTAssertEqual(p[1], 0x04)

        // All three set → 0x07
        p = SatelliteClient.encodeTouchpadPayload(
            controllerIndex: 0,
            finger0Active: true, finger0Id: 0, finger0X: 0, finger0Y: 0,
            finger1Active: true, finger1Id: 0, finger1X: 0, finger1Y: 0,
            buttonPressed: true
        )
        XCTAssertEqual(p[1], 0x07)
    }

    func testTouchpadFingerCoordsAreLittleEndianInt16() {
        let p = SatelliteClient.encodeTouchpadPayload(
            controllerIndex: 9,
            finger0Active: true, finger0Id: 0x11,
            finger0X: 0x0102, finger0Y: 0x0304,
            finger1Active: true, finger1Id: 0x22,
            finger1X: 0x0506, finger1Y: 0x0708,
            buttonPressed: false
        )
        XCTAssertEqual(p[0], 9)
        XCTAssertEqual(p[1], 0x03) // both fingers active
        XCTAssertEqual(p[2], 0x11) // finger0 id
        // finger0 X = 0x0102 → LE: 0x02, 0x01
        XCTAssertEqual(p[3], 0x02)
        XCTAssertEqual(p[4], 0x01)
        // finger0 Y = 0x0304 → LE: 0x04, 0x03
        XCTAssertEqual(p[5], 0x04)
        XCTAssertEqual(p[6], 0x03)
        XCTAssertEqual(p[7], 0x22) // finger1 id
        // finger1 X = 0x0506 → LE: 0x06, 0x05
        XCTAssertEqual(p[8], 0x06)
        XCTAssertEqual(p[9], 0x05)
        // finger1 Y = 0x0708 → LE: 0x08, 0x07
        XCTAssertEqual(p[10], 0x08)
        XCTAssertEqual(p[11], 0x07)
    }

    func testTouchpadCoordsCoverFullInt16Range() {
        let p = SatelliteClient.encodeTouchpadPayload(
            controllerIndex: 0,
            finger0Active: true, finger0Id: 0, finger0X: Int16.min, finger0Y: Int16.max,
            finger1Active: true, finger1Id: 0, finger1X: -1, finger1Y: 0,
            buttonPressed: false
        )
        // Int16.min = -32768 = 0x8000 (two's complement) → LE: 0x00, 0x80
        XCTAssertEqual(p[3], 0x00)
        XCTAssertEqual(p[4], 0x80)
        // Int16.max = 32767 = 0x7FFF → LE: 0xFF, 0x7F
        XCTAssertEqual(p[5], 0xFF)
        XCTAssertEqual(p[6], 0x7F)
        // -1 = 0xFFFF → LE: 0xFF, 0xFF
        XCTAssertEqual(p[8], 0xFF)
        XCTAssertEqual(p[9], 0xFF)
    }

    // MARK: - parseLightbarMessage

    func testLightbarDecodesAllFields() {
        let bytes: [UInt8] = [3, 0xDE, 0xAD, 0xBE]
        let msg = SatelliteClient.parseLightbarMessage(bytes[...])
        XCTAssertNotNil(msg)
        XCTAssertEqual(msg?.controllerIndex, 3)
        XCTAssertEqual(msg?.r, 0xDE)
        XCTAssertEqual(msg?.g, 0xAD)
        XCTAssertEqual(msg?.b, 0xBE)
    }

    func testLightbarRejectsTruncatedPayload() {
        let tooShort: [UInt8] = [0, 0, 0] // only 3 bytes
        XCTAssertNil(SatelliteClient.parseLightbarMessage(tooShort[...]))
        XCTAssertNil(SatelliteClient.parseLightbarMessage(ArraySlice<UInt8>()))
    }

    func testLightbarToleratesTrailingBytesForwardCompat() {
        // Future protocol versions may append fields; current decoder must
        // still succeed on the leading 4 bytes and ignore the tail.
        let bytes: [UInt8] = [1, 0x11, 0x22, 0x33, 0xFF, 0xFF, 0xFF]
        let msg = SatelliteClient.parseLightbarMessage(bytes[...])
        XCTAssertNotNil(msg)
        XCTAssertEqual(msg?.r, 0x11)
        XCTAssertEqual(msg?.g, 0x22)
        XCTAssertEqual(msg?.b, 0x33)
    }

    func testLightbarFullRGBRange() {
        // (0, 0, 0) → black; (255, 255, 255) → white. Verify the parser
        // doesn't sign-extend the bytes.
        let black: [UInt8] = [0, 0, 0, 0]
        let white: [UInt8] = [0, 0xFF, 0xFF, 0xFF]
        XCTAssertEqual(SatelliteClient.parseLightbarMessage(black[...])?.r, 0)
        XCTAssertEqual(SatelliteClient.parseLightbarMessage(white[...])?.r, 0xFF)
        XCTAssertEqual(SatelliteClient.parseLightbarMessage(white[...])?.g, 0xFF)
        XCTAssertEqual(SatelliteClient.parseLightbarMessage(white[...])?.b, 0xFF)
    }

    // MARK: - Constants

    func testMessageTypeConstants() {
        XCTAssertEqual(SatelliteClient.msgLightbar, 0x000D)
        // msgTouchpad is private; the encoder coverage above pins the byte
        // path that uses it.
    }
}
