// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import XCTest
@testable import Dish

final class HexTests: XCTestCase {

    func testHexToBytesRoundTripLower() {
        let data = Data([0x00, 0x01, 0xFE, 0xFF, 0xAB, 0xCD])
        XCTAssertEqual(data.hexString, "0001feffabcd")
        XCTAssertEqual(hexToBytes("0001feffabcd"), data)
    }

    func testHexToBytesAcceptsUppercase() {
        XCTAssertEqual(hexToBytes("ABCD"), Data([0xAB, 0xCD]))
    }

    func testHexToBytesRejectsOddLength() {
        XCTAssertNil(hexToBytes("abc"))
    }

    func testHexToBytesRejectsNonHex() {
        XCTAssertNil(hexToBytes("zzzz"))
        XCTAssertNil(hexToBytes("12g4"))
    }

    func testHexToBytesRejectsSignAndWhitespacePairs() {
        // `UInt8(_, radix:)` parses "+5" as 5 — a strict decoder must not.
        XCTAssertNil(hexToBytes("+5"))
        XCTAssertNil(hexToBytes("-0"))
        XCTAssertNil(hexToBytes(" a"))
        XCTAssertNil(hexToBytes("ab+5"))
    }

    func testHexToBytesEmpty() {
        XCTAssertEqual(hexToBytes(""), Data())
    }

    func testPutBE16EncodesBigEndian() {
        var buf = [UInt8](repeating: 0, count: 2)
        putBE16(0xBEEF, into: &buf, at: 0)
        XCTAssertEqual(buf, [0xBE, 0xEF])
    }

    func testPutBE16EncodesZero() {
        var buf = [UInt8](repeating: 0xFF, count: 2)
        putBE16(0, into: &buf, at: 0)
        XCTAssertEqual(buf, [0x00, 0x00])
    }

    func testPutBE32EncodesBigEndian() {
        var buf = [UInt8](repeating: 0, count: 4)
        putBE32(0xDEAD_BEEF, into: &buf, at: 0)
        XCTAssertEqual(buf, [0xDE, 0xAD, 0xBE, 0xEF])
    }

    func testPutBE32EncodesAtOffset() {
        var buf = [UInt8](repeating: 0xAA, count: 8)
        putBE32(0x1234_5678, into: &buf, at: 4)
        XCTAssertEqual(buf, [0xAA, 0xAA, 0xAA, 0xAA, 0x12, 0x34, 0x56, 0x78])
    }

    func testPutBE32EncodesMaxValue() {
        var buf = [UInt8](repeating: 0, count: 4)
        putBE32(UInt32.max, into: &buf, at: 0)
        XCTAssertEqual(buf, [0xFF, 0xFF, 0xFF, 0xFF])
    }
}
