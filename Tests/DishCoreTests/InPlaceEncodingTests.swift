// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import CryptoKit
import DishCore
import XCTest

/// The send path writes every payload, header and box into one stack buffer:
/// each writer must lay down exactly the bytes the `Data` encoder returns.
final class InPlaceEncodingTests: XCTestCase {

    private let key = SymmetricKey(data: Data(repeating: 0x42, count: 32))
    private let sample = TouchpadSample(
        finger0: TouchpadFinger(active: true, id: 7, x: -1200, y: 3400),
        finger1: TouchpadFinger(active: false, id: 2, x: 5, y: -6),
        buttonPressed: true
    )

    private func written(_ count: Int, _ write: (UnsafeMutableRawBufferPointer) -> Void) -> Data {
        var out = Data(repeating: 0xEE, count: count)
        out.withUnsafeMutableBytes { write($0) }
        return out
    }

    func testEveryPayloadWriterLaysDownTheEncodersBytes() {
        let report = GamepadReport(buttons: 0xA55A, lt: 3, rt: 250, lx: -32768, ly: 32767, rx: -1, ry: 1234, extButtons: 0x1003)
        XCTAssertEqual(
            written(13) { Encoders.writeInputPayload(controllerIndex: 2, report: report, settledVersion: 3, into: $0) },
            Encoders.inputPayload(controllerIndex: 2, report: report, settledVersion: 3)
        )
        XCTAssertEqual(
            written(17) { Encoders.writeInputPayload(controllerIndex: 2, report: report, settledVersion: 4, into: $0) },
            Encoders.inputPayload(controllerIndex: 2, report: report, settledVersion: 4)
        )
        let motion = MotionSample(gyroX: -5, gyroY: 6, gyroZ: -7, accelX: 8192, accelY: -8192, accelZ: 1)
        XCTAssertEqual(
            written(17) { Encoders.writeMotionPayload(controllerIndex: 1, sample: motion, timestampDeltaUs: 0xDEAD_BEEF, into: $0) },
            Encoders.motionPayload(controllerIndex: 1, sample: motion, timestampDeltaUs: 0xDEAD_BEEF)
        )
        XCTAssertEqual(
            written(3) { Encoders.writeBatteryPayload(controllerIndex: 3, level: 77, status: .charging, into: $0) },
            Encoders.batteryPayload(controllerIndex: 3, level: 77, status: .charging)
        )
        XCTAssertEqual(
            written(16) { Encoders.writeTouchpadPayload(controllerIndex: 0, sample: sample, eventTimeMs: 0x0102_0304, into: $0) },
            Encoders.touchpadPayload(controllerIndex: 0, sample: sample, eventTimeMs: 0x0102_0304)
        )
        XCTAssertEqual(
            written(19) { Encoders.writePointerPayload(controllerIndex: 0, sample: sample, eventTimeMs: 9, scrollV: -120, into: $0) },
            Encoders.pointerPayload(controllerIndex: 0, sample: sample, eventTimeMs: 9, scrollV: -120)
        )
    }

    func testTheHeaderWritersLayDownTheFramesHeaders() {
        let payload = Data([1, 2, 3])
        XCTAssertEqual(
            written(4) { PacketCodec.writeInnerHeader(msgType: ProtocolConstants.msgTouchpad, payloadCount: payload.count, into: $0) },
            PacketCodec.innerFrame(msgType: ProtocolConstants.msgTouchpad, payload: payload).prefix(4)
        )
        XCTAssertEqual(
            written(8) { PacketCodec.writeHeader(token: 0xAABB_CCDD, counter: 0xF000_0001, into: $0) },
            PacketCodec.frame(token: 0xAABB_CCDD, counter: 0xF000_0001, box: Data()).prefix(8)
        )
    }

    func testAnAudioFrameWritesItsOwnPayload() {
        let frame = AudioFrame(controllerIndex: 2, seq: 0x0A0B, opus: Data([9, 8, 7, 6]))
        XCTAssertEqual(frame.payloadCount, frame.payload.count)
        XCTAssertEqual(written(frame.payloadCount) { frame.writePayload(into: $0) }, frame.payload)
    }

    /// The send seals the inner frame where it lies: the box overwrites the
    /// plaintext it was sealed from, and is the box `seal` returns.
    func testABoxSealedOverItsOwnPlaintextIsTheBoxSealed() throws {
        let inner = PacketCodec.innerFrame(msgType: ProtocolConstants.msgInput, payload: Data(0 ..< 13))
        let expected = try SessionCrypto.seal(inner, key: key, direction: .up, counter: 41, token: 0x0007_A1B2)
        var buffer = inner + Data(count: ProtocolConstants.authTagSize)
        let count = try buffer.withUnsafeMutableBytes { raw in
            try SessionCrypto.seal(
                UnsafeRawBufferPointer(rebasing: raw[..<inner.count]),
                into: raw,
                key: key,
                direction: .up,
                counter: 41,
                token: 0x0007_A1B2
            )
        }
        XCTAssertEqual(count, inner.count + ProtocolConstants.authTagSize)
        XCTAssertEqual(buffer, expected)
        let opened = try SessionCrypto.open(buffer, key: key, direction: .up, counter: 41, token: 0x0007_A1B2)
        XCTAssertEqual(opened, inner)
    }
}
