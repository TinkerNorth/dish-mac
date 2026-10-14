// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import CryptoKit
import XCTest
@testable import DishCore

/// The whole encrypted frame around Wolf's captures, the ways a frame can
/// fail to open, and the one counter every outbound packet takes.
final class MoonlightControlPacketTests: XCTestCase {

    private let rikey = hexData("edf04a215c4fbea20934120c8480d855")
    private var key: SymmetricKey {
        SymmetricKey(data: rikey)
    }

    /// seq, plaintext, full frame.
    private let frames: [(seq: UInt32, plaintext: String, frame: String)] = [
        (0, "020302000000", "01001a0000000000bf0eb6da10e47c702ec8644eb87d9cf7b6fac9ff75ca"),
        (1, "0703010000", "010019000100000021dbb8dc0590af3a2b20bce5a347de31d366e5b9c5"),
        (2, "000208000400000000000000", "0100200002000000220722fbaded58a03f2e8898f0f1dcb7c93f6235590618e4186ad990"),
        (
            6,
            "060212000000000e05000000033400c00000059f0329",
            "01002a00060000005a4d999fb2542f85bdd39d99f77eb825254569d2c04e21241b5cec01bd3f93129718ecc1f153"
        )
    ]

    func testSealsFullFramesByteForByte() {
        for entry in frames {
            let sealed = MoonlightControlPacket.seal(key: key, seq: entry.seq, plaintext: hexData(entry.plaintext))
            XCTAssertEqual(sealed.map(hexString), entry.frame, "seq \(entry.seq)")
        }
    }

    func testTheLengthCountsSeqTagAndCiphertext() {
        let frame = hexData(frames[0].frame)
        XCTAssertEqual(Array(frame.prefix(4)), [0x01, 0x00, 0x1A, 0x00], "type 0x0001, length 26 = 4 + 16 + 6")
        XCTAssertEqual(frame.count, 4 + 26)
    }

    func testOpensEveryFrame() {
        for entry in frames {
            XCTAssertEqual(
                MoonlightControlPacket.open(key: key, packet: hexData(entry.frame)),
                .plaintext(hexData(entry.plaintext)),
                "seq \(entry.seq)"
            )
        }
    }

    func testAShortFrameTheWrongTypeOrALyingLengthIsMalformed() {
        let frame = hexData(frames[0].frame)
        XCTAssertEqual(MoonlightControlPacket.open(key: key, packet: frame.prefix(23)), .malformed, "shorter than header + seq + tag")
        XCTAssertEqual(MoonlightControlPacket.open(key: key, packet: Data()), .malformed)
        var wrongType = frame
        wrongType[0] = 0x02
        XCTAssertEqual(MoonlightControlPacket.open(key: key, packet: wrongType), .malformed)
        var lying = frame
        lying[2] = 0x1B
        XCTAssertEqual(MoonlightControlPacket.open(key: key, packet: lying), .malformed, "one byte more than the frame holds")
        var tooSmall = frame
        tooSmall[2] = 0x13
        XCTAssertEqual(MoonlightControlPacket.open(key: key, packet: tooSmall), .malformed, "a length that cannot hold seq + tag")
    }

    func testATamperedCiphertextIsForgedNotMalformed() {
        var frame = hexData(frames[0].frame)
        frame[frame.count - 1] ^= 0x80
        XCTAssertEqual(MoonlightControlPacket.open(key: key, packet: frame), .forged)
        var tag = hexData(frames[1].frame)
        tag[8] ^= 0x01
        XCTAssertEqual(MoonlightControlPacket.open(key: key, packet: tag), .forged)
    }

    func testTheSealerStartsAtZeroAndCountsEveryKindOfPacket() {
        var sealer = MoonlightControlSealer(rikey: rikey)
        XCTAssertEqual(sealer.nextSeq, 0)
        XCTAssertEqual(sealer.seal(hexData(frames[0].plaintext)).map(hexString), frames[0].frame)
        XCTAssertEqual(sealer.seal(hexData(frames[1].plaintext)).map(hexString), frames[1].frame)
        XCTAssertEqual(sealer.seal(hexData(frames[2].plaintext)).map(hexString), frames[2].frame, "a ping takes a number like any input")
        XCTAssertEqual(sealer.nextSeq, 3)
    }

    func testTheSealerWrapsItsCounterInsteadOfTrapping() {
        var sealer = MoonlightControlSealer(rikey: rikey)
        for _ in 0 ..< 3 {
            _ = sealer.seal(Data([0x00]))
        }
        XCTAssertEqual(sealer.nextSeq, 3)
        XCTAssertEqual(
            MoonlightControlSealer(rikey: rikey),
            MoonlightControlSealer(rikey: rikey),
            "a fresh sealer per launch, equal to another"
        )
    }
}
