// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// Pins the cleartext packet framing (token(4 BE) | counter(4 BE) | box) and
// the inner frame (msgType(2 BE) | msgLen(2 BE) | payload) byte-for-byte
// against contract §Crypto, and proves the full seal→frame→parse→open path
// round-trips with the counters-start-at-1 convention.

import CryptoKit
import XCTest
import DishCore

final class PacketCodecTests: XCTestCase {

    func testFrameLaysOutTokenAndCounterBigEndian() {
        // A 2-byte "box" is below the parse minimum on purpose: this test pins
        // the BUILD layout only.
        let packet = PacketCodec.frame(token: 0x0007_A1B2, counter: 1, box: Data([0xDE, 0xAD]))
        XCTAssertEqual(
            [UInt8](packet),
            [0x00, 0x07, 0xA1, 0xB2, 0x00, 0x00, 0x00, 0x01, 0xDE, 0xAD]
        )
    }

    func testParseSplitsHeaderAndBoxAndRejectsRunts() throws {
        let box = Data([UInt8](repeating: 0x5A, count: 16)) // tag-sized minimum
        let packet = PacketCodec.frame(token: 0xAABB_CCDD, counter: 0xF000_0001, box: box)

        let parsed = try XCTUnwrap(PacketCodec.parse(packet))
        XCTAssertEqual(parsed.header, PacketCodec.Header(token: 0xAABB_CCDD, counter: 0xF000_0001))
        XCTAssertEqual(parsed.box, box)

        // Shorter than header(8) + tag(16) cannot carry a sealed message.
        XCTAssertNil(PacketCodec.parse(packet.prefix(23)))
        XCTAssertNil(PacketCodec.parse(Data()))
    }

    func testInnerFrameLaysOutTypeAndLengthBigEndian() {
        // A heartbeat: empty payload.
        XCTAssertEqual(
            [UInt8](PacketCodec.innerFrame(msgType: 0x0002, payload: Data())),
            [0x00, 0x02, 0x00, 0x00]
        )
        // A payload-carrying frame: msgLen is the true payload length.
        XCTAssertEqual(
            [UInt8](PacketCodec.innerFrame(msgType: 0x000C, payload: Data([0xAA, 0xBB, 0xCC]))),
            [0x00, 0x0C, 0x00, 0x03, 0xAA, 0xBB, 0xCC]
        )
    }

    func testParseInnerRoundTripsAndRejectsRunts() throws {
        let payload = Data([1, 2, 3, 4, 5])
        let frame = PacketCodec.innerFrame(msgType: ProtocolConstants.msgRumble, payload: payload)
        let inner = try XCTUnwrap(PacketCodec.parseInner(frame))
        XCTAssertEqual(inner.msgType, ProtocolConstants.msgRumble)
        XCTAssertEqual(inner.declaredLength, 5)
        XCTAssertEqual(inner.payload, payload)

        XCTAssertNil(PacketCodec.parseInner(Data([0x00, 0x02, 0x00])))
        XCTAssertNil(PacketCodec.parseInner(Data()))
    }

    func testParseInnerUsesRemainingLengthLikeTheSiblingClients() throws {
        // The clients parse by REMAINING length (a newer server may append
        // extension bytes); the sender-declared msgLen is surfaced for callers
        // wanting the stricter satellite-receiver check.
        let frame = Data([0x00, 0x03, 0x00, 0x02, 0xAA, 0xBB, 0xCC])
        let inner = try XCTUnwrap(PacketCodec.parseInner(frame))
        XCTAssertEqual(inner.msgType, 0x0003)
        XCTAssertEqual(inner.declaredLength, 2)
        XCTAssertEqual(inner.payload, Data([0xAA, 0xBB, 0xCC]))
    }

    func testFullDatagramRoundTripWithCounterStartingAtOne() throws {
        // innerFrame → seal → frame → parse → open → parseInner, under the
        // exact conventions the wire uses: counters start at 1, AAD = token,
        // direction byte in the nonce.
        let key = SymmetricKey(data: interopKey())
        let token: UInt32 = 0x0007_A1B2
        let inner = PacketCodec.innerFrame(msgType: ProtocolConstants.msgHeartbeat, payload: Data())

        let box = try SessionCrypto.seal(inner, key: key, direction: .up, counter: 1, token: token)
        let datagram = PacketCodec.frame(token: token, counter: 1, box: box)

        let parsed = try XCTUnwrap(PacketCodec.parse(datagram))
        XCTAssertEqual(parsed.header.token, token)
        XCTAssertEqual(parsed.header.counter, 1)

        let plain = try SessionCrypto.open(
            parsed.box,
            key: key,
            direction: .up,
            counter: parsed.header.counter,
            token: parsed.header.token
        )
        let message = try XCTUnwrap(PacketCodec.parseInner(plain))
        XCTAssertEqual(message.msgType, ProtocolConstants.msgHeartbeat)
        XCTAssertEqual(message.declaredLength, 0)
        XCTAssertTrue(message.payload.isEmpty)
    }
}
