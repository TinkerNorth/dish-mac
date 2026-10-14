// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import CryptoKit
import XCTest
@testable import DishCore

/// The seal against Wolf's captured session, byte for byte, the same four
/// packets dish-android, dish-linux and dish-windows pin: any drift here is
/// a real interop break, not a style difference.
final class MoonlightControlSealTests: XCTestCase {

    private let rikey = hexData("edf04a215c4fbea20934120c8480d855")
    private var key: SymmetricKey {
        SymmetricKey(data: rikey)
    }

    /// seq, plaintext, and the `tag || ciphertext` the wire carried.
    static let captures: [(seq: UInt32, plaintext: String, body: String)] = [
        (0, "020302000000", "bf0eb6da10e47c702ec8644eb87d9cf7b6fac9ff75ca"),
        (1, "0703010000", "21dbb8dc0590af3a2b20bce5a347de31d366e5b9c5"),
        (2, "000208000400000000000000", "220722fbaded58a03f2e8898f0f1dcb7c93f6235590618e4186ad990"),
        (
            6,
            "060212000000000e05000000033400c00000059f0329",
            "5a4d999fb2542f85bdd39d99f77eb825254569d2c04e21241b5cec01bd3f93129718ecc1f153"
        )
    ]

    func testSealsWolfsCapturedPacketsByteForByte() {
        for capture in Self.captures {
            let sealed = MoonlightControlSeal.seal(key: key, seq: capture.seq, plaintext: hexData(capture.plaintext))
            XCTAssertEqual(sealed.map(hexString), capture.body, "seq \(capture.seq)")
        }
    }

    func testOpensThemBack() {
        for capture in Self.captures {
            let opened = MoonlightControlSeal.open(key: key, seq: capture.seq, tagThenCiphertext: hexData(capture.body))
            XCTAssertEqual(opened.map(hexString), capture.plaintext, "seq \(capture.seq)")
        }
    }

    func testTheTagPrecedesTheCiphertext() {
        let body = hexData(Self.captures[0].body)
        XCTAssertEqual(hexString(body.prefix(16)), "bf0eb6da10e47c702ec8644eb87d9cf7")
        XCTAssertEqual(hexString(body.dropFirst(16)), "b6fac9ff75ca", "six plaintext bytes, six ciphertext bytes")
    }

    /// The host assigns a u32 into a u8: only the low byte reaches the IV,
    /// so the 257th packet seals exactly like the first.
    func testTheIvIsSixteenZeroBytesWithTheLowByteOfTheSeq() {
        XCTAssertEqual(hexString(MoonlightControlSeal.iv(seq: 300)), "2c000000000000000000000000000000")
        XCTAssertEqual(hexString(MoonlightControlSeal.iv(seq: 0x0102_0304)), "04000000000000000000000000000000")
        let plaintext = hexData("0703010000")
        XCTAssertEqual(
            MoonlightControlSeal.seal(key: key, seq: 257, plaintext: plaintext),
            MoonlightControlSeal.seal(key: key, seq: 1, plaintext: plaintext)
        )
        XCTAssertNotEqual(
            MoonlightControlSeal.seal(key: key, seq: 2, plaintext: plaintext),
            MoonlightControlSeal.seal(key: key, seq: 1, plaintext: plaintext)
        )
    }

    func testATamperedByteAWrongKeyOrAWrongSeqIsRejected() {
        var body = hexData(Self.captures[0].body)
        body[body.count - 1] ^= 0x01
        XCTAssertNil(MoonlightControlSeal.open(key: key, seq: 0, tagThenCiphertext: body))
        let intact = hexData(Self.captures[0].body)
        XCTAssertNil(MoonlightControlSeal.open(key: SymmetricKey(size: .bits128), seq: 0, tagThenCiphertext: intact))
        XCTAssertNil(MoonlightControlSeal.open(key: key, seq: 1, tagThenCiphertext: intact))
    }

    func testABodyShorterThanTheTagIsRejected() {
        XCTAssertNil(MoonlightControlSeal.open(key: key, seq: 0, tagThenCiphertext: Data(count: 15)))
        XCTAssertNil(MoonlightControlSeal.open(key: key, seq: 0, tagThenCiphertext: Data()))
    }
}
