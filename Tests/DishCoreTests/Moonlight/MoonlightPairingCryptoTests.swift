// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import XCTest
@testable import DishCore

/// The pairing primitives against Wolf's published vectors, FIPS-197, and
/// the derivation dish-linux pins.
final class MoonlightPairingCryptoTests: XCTestCase {

    func testThePinDerivesTheKeyWolfPublished() {
        let key = MoonlightPairingCrypto.pairingKey(salt: hexData("ff5dc6eda99339a8a0793e216c4257c4"), pin: "5338")
        XCTAssertEqual(hexString(key), "5ea186ffba663c75aec82187ce502647")
        let linux = MoonlightPairingCrypto.pairingKey(salt: Data(0 ... 15), pin: "4989")
        XCTAssertEqual(hexString(linux), "1e3644c22cb825f6944041deab6c5cfb")
    }

    func testAesEcbDecryptsWolfsChallengeAndEncryptsItBack() {
        let key = hexData("5ea186ffba663c75aec82187ce502647")
        let ciphertext = hexData("c05930ac81d7bd426344235436046018")
        let plaintext = MoonlightPairingCrypto.aesEcbDecrypt(key: key, data: ciphertext)
        XCTAssertEqual(plaintext.map(hexString), "e3a915cccb4c60206077d7e9a12316a5")
        XCTAssertEqual(plaintext.flatMap { MoonlightPairingCrypto.aesEcbEncrypt(key: key, data: $0) }, ciphertext)
    }

    func testAesEcbMatchesFips197() {
        let key = hexData("000102030405060708090a0b0c0d0e0f")
        let block = hexData("00112233445566778899aabbccddeeff")
        XCTAssertEqual(MoonlightPairingCrypto.aesEcbEncrypt(key: key, data: block).map(hexString), "69c4e0d86a7b0430d8cdb78070b4c55a")
        let three = block + block + block
        XCTAssertEqual(MoonlightPairingCrypto.aesEcbEncrypt(key: key, data: three)?.count, 48, "whole blocks, no padding")
    }

    func testAesEcbRefusesAPartialBlockOrAWrongKey() {
        let key = hexData("000102030405060708090a0b0c0d0e0f")
        XCTAssertNil(MoonlightPairingCrypto.aesEcbEncrypt(key: key, data: Data(count: 15)))
        XCTAssertNil(MoonlightPairingCrypto.aesEcbEncrypt(key: key, data: Data()))
        XCTAssertNil(MoonlightPairingCrypto.aesEcbEncrypt(key: Data(count: 24), data: Data(count: 16)), "the pairing key is 128 bits")
    }

    func testSha256AndTheConstantTimeCompare() {
        XCTAssertEqual(
            hexString(MoonlightPairingCrypto.sha256(Data("abc".utf8))),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
        XCTAssertEqual(
            MoonlightPairingCrypto.sha256(Data("a".utf8), Data("bc".utf8)),
            MoonlightPairingCrypto.sha256(Data("abc".utf8)),
            "parts concatenate"
        )
        XCTAssertTrue(MoonlightPairingCrypto.constantTimeEquals(hexData("0102"), hexData("0102")))
        XCTAssertFalse(MoonlightPairingCrypto.constantTimeEquals(hexData("0102"), hexData("0103")))
        XCTAssertFalse(MoonlightPairingCrypto.constantTimeEquals(hexData("0102"), hexData("010203")))
    }
}
