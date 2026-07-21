// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// Pins DishCore's module-internal hex codec, in particular the strict
// alphabet: `UInt8(_, radix:)` accepts sign/whitespace-prefixed pairs, which
// would silently break the hmacProof "False on malformed hex" contract.

import XCTest
@testable import DishCore

final class HexDecodeTests: XCTestCase {

    func testDecodesBothCasesAndRoundTrips() {
        let data = Data([0x00, 0x01, 0xFE, 0xFF, 0xAB, 0xCD])
        XCTAssertEqual(hexDecode("0001feffabcd"), data)
        XCTAssertEqual(hexDecode("0001FEFFABCD"), data)
        XCTAssertEqual(hexDecode(hexEncodeLower(data)), data)
        XCTAssertEqual(hexDecode(""), Data())
    }

    func testRejectsOddLengthAndNonHex() {
        XCTAssertNil(hexDecode("abc"))
        XCTAssertNil(hexDecode("zz"))
        XCTAssertNil(hexDecode("12g4"))
    }

    func testRejectsSignAndWhitespacePairs() {
        XCTAssertNil(hexDecode("+5"))
        XCTAssertNil(hexDecode("-0"))
        XCTAssertNil(hexDecode(" a"))
        XCTAssertNil(hexDecode("ab+5"))
    }
}
