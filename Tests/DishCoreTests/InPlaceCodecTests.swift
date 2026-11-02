// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import CryptoKit
import DishCore
import XCTest

/// The receive loop parses and opens each datagram where it lies, in its
/// buffer, and reads payloads as slices of the plaintext: every in-place
/// read must agree with the copying one, and every parser must read a slice
/// from its own start.
final class InPlaceCodecTests: XCTestCase {

    private let key = SymmetricKey(data: Data(repeating: 0x42, count: 32))
    private let token: UInt32 = 0x0007_A1B2

    private func sealed(_ msgType: UInt16, _ payload: Data, counter: UInt32) throws -> Data {
        let inner = PacketCodec.innerFrame(msgType: msgType, payload: payload)
        let box = try SessionCrypto.seal(inner, key: key, direction: .down, counter: counter, token: token)
        return PacketCodec.frame(token: token, counter: counter, box: box)
    }

    /// A copy of `data` that starts at a non-zero index, as a slice of a
    /// plaintext does.
    private func offsetSlice(_ data: Data) -> Data {
        (Data([0xEE, 0xEE, 0xEE]) + data).dropFirst(3)
    }

    func testTheHeaderReadInPlaceIsTheHeaderParsed() throws {
        let packet = try sealed(ProtocolConstants.msgRumble, Data([0, 1, 2, 3, 4, 5, 6]), counter: 0xF000_0001)
        let copied = try XCTUnwrap(PacketCodec.parse(packet)).header
        let inPlace = try XCTUnwrap(packet.withUnsafeBytes { PacketCodec.parseHeader($0) })
        XCTAssertEqual(inPlace, copied)
        XCTAssertEqual(inPlace, PacketCodec.Header(token: token, counter: 0xF000_0001))
    }

    func testTheHeaderReadInPlaceRejectsWhatParseRejects() {
        let runt = Data(repeating: 0x5A, count: ProtocolConstants.headerSize + ProtocolConstants.authTagSize - 1)
        XCTAssertNil(runt.withUnsafeBytes { PacketCodec.parseHeader($0) })
        XCTAssertNil(PacketCodec.parse(runt))
    }

    func testABoxOpenedInPlaceIsTheBoxOpened() throws {
        let packet = try sealed(ProtocolConstants.msgLightbar, Data([1, 0, 64, 255]), counter: 9)
        let box = Data(packet.dropFirst(ProtocolConstants.headerSize))
        let copied = try SessionCrypto.open(box, key: key, direction: .down, counter: 9, token: token)
        let inPlace = try packet.withUnsafeBytes { raw in
            try SessionCrypto.open(
                boxBytes: UnsafeRawBufferPointer(rebasing: raw[ProtocolConstants.headerSize...]),
                key: key,
                direction: .down,
                counter: 9,
                token: token
            )
        }
        XCTAssertEqual(inPlace, copied)
        XCTAssertEqual(PacketCodec.parseInner(copied)?.payload, Data([1, 0, 64, 255]))
    }

    func testABoxOpenedInPlaceStillBindsCounterTokenAndDirection() throws {
        let packet = try sealed(ProtocolConstants.msgLightbar, Data([1, 0, 64, 255]), counter: 9)
        try packet.withUnsafeBytes { raw in
            let box = UnsafeRawBufferPointer(rebasing: raw[ProtocolConstants.headerSize...])
            XCTAssertThrowsError(try SessionCrypto.open(boxBytes: box, key: key, direction: .down, counter: 10, token: token))
            XCTAssertThrowsError(try SessionCrypto.open(boxBytes: box, key: key, direction: .down, counter: 9, token: token + 1))
            XCTAssertThrowsError(try SessionCrypto.open(boxBytes: box, key: key, direction: .up, counter: 9, token: token))
            XCTAssertNoThrow(try SessionCrypto.open(boxBytes: box, key: key, direction: .down, counter: 9, token: token))
        }
    }

    func testAShortBoxOpenedInPlaceIsMalformed() {
        let short = Data(repeating: 0, count: ProtocolConstants.authTagSize - 1)
        XCTAssertThrowsError(try short.withUnsafeBytes { raw in
            try SessionCrypto.open(boxBytes: raw, key: key, direction: .down, counter: 1, token: token)
        }) { error in
            XCTAssertEqual(error as? SessionCryptoError, .malformedBox)
        }
    }

    func testTheInnerMessageInPlaceIsTheInnerMessageParsed() throws {
        let frame = PacketCodec.innerFrame(msgType: ProtocolConstants.msgRumble, payload: Data([1, 2, 3, 4, 5, 6, 7]))
        let copied = try XCTUnwrap(PacketCodec.parseInner(frame))
        let inPlace = try XCTUnwrap(PacketCodec.parseInnerInPlace(offsetSlice(frame)))
        XCTAssertEqual(inPlace.msgType, copied.msgType)
        XCTAssertEqual(inPlace.declaredLength, copied.declaredLength)
        XCTAssertEqual(inPlace.payload, copied.payload)
        XCTAssertNil(PacketCodec.parseInnerInPlace(Data([0x00, 0x09, 0x00])))
    }

    func testEveryReturnPathParserReadsASliceFromItsOwnStart() throws {
        let rumble = Data([2, 0x75, 0x30, 0x27, 0x10, 0x01, 0xF4])
        XCTAssertEqual(RumbleCommand.parse(offsetSlice(rumble)), RumbleCommand.parse(rumble))
        XCTAssertEqual(
            RumbleCommand.parse(offsetSlice(rumble)),
            RumbleCommand(controllerIndex: 2, strongMagnitude: 30000, weakMagnitude: 10000, durationMs: 500)
        )
        let lightbar = Data([1, 0, 64, 255])
        XCTAssertEqual(LightbarCommand.parse(offsetSlice(lightbar)), LightbarCommand(controllerIndex: 1, r: 0, g: 64, b: 255))
        let ack = Data([1, 2, 0x01, 0x02, 0x00, 0x05])
        XCTAssertEqual(HeartbeatAck.parse(offsetSlice(ack)), HeartbeatAck(backendAvailable: true, activeCount: 2, epoch: 0x0102, bitmap: 5))
        let audio = Data([3, 0x01, 0x02, 0xAA, 0xBB])
        let frame = try XCTUnwrap(AudioFrame.parse(offsetSlice(audio)))
        XCTAssertEqual(frame, AudioFrame.parse(audio))
        XCTAssertEqual(frame.opus.startIndex, 0, "the frame owns its Opus bytes, indexed from 0")
        XCTAssertEqual(frame.opus, Data([0xAA, 0xBB]))
    }

    func testTheReturnPathParsersStillRejectShortPayloads() {
        XCTAssertNil(RumbleCommand.parse(offsetSlice(Data([2, 0x75, 0x30, 0x27, 0x10, 0x01]))))
        XCTAssertNil(LightbarCommand.parse(offsetSlice(Data([1, 0, 64]))))
        XCTAssertNil(HeartbeatAck.parse(offsetSlice(Data([1, 2, 0x01, 0x02, 0x00]))))
        XCTAssertNil(AudioFrame.parse(offsetSlice(Data([3, 0x01, 0x02]))))
    }
}
