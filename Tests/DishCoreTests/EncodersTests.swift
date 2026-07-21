// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// Byte-layout pins for the pure inner-payload encoders and the return-path
// parsers, against satellite/src/core/types.h decode order (explicit LE for
// coordinates/timestamps, BE for the ack/rumble u16 fields). The 16-byte
// touchpad layout with the trailing eventTimeMs u32 LE @ offset 12 is the
// protocol-1 shape the server requires (legacy 12-byte bodies are dropped).

import DishCore
import XCTest

final class EncodersTests: XCTestCase {

    // MARK: - MSG_INPUT (0x0001)

    func testInputPayloadPinsTheXusbLittleEndianLayout() {
        let payload = Encoders.inputPayload(
            controllerIndex: 3,
            buttons: 0xABCD,
            lt: 0x11,
            rt: 0x22,
            lx: 0x1234,
            ly: -2,
            rx: Int16.max,
            ry: Int16.min
        )
        XCTAssertEqual(payload.count, ProtocolConstants.inputPayloadBytes)
        XCTAssertEqual(
            [UInt8](payload),
            [
                3, // ctrlIdx
                0xCD, 0xAB, // buttons LE
                0x11, 0x22, // triggers
                0x34, 0x12, // lx LE
                0xFE, 0xFF, // ly = -2
                0xFF, 0x7F, // rx = 32767
                0x00, 0x80 // ry = -32768
            ]
        )
    }

    // MARK: - MSG_MOTION (0x000A)

    func testMotionPayloadPinsTheSeventeenByteLittleEndianLayout() {
        let payload = Encoders.motionPayload(
            controllerIndex: 1,
            gyroX: 0x1234,
            gyroY: -1,
            gyroZ: 2,
            accelX: -32768,
            accelY: 32767,
            accelZ: 0,
            timestampDeltaUs: 0xAABB_CCDD
        )
        XCTAssertEqual(payload.count, ProtocolConstants.motionPayloadBytes)
        XCTAssertEqual(
            [UInt8](payload),
            [
                1, // ctrlIdx
                0x34, 0x12, // gyroX LE
                0xFF, 0xFF, // gyroY = -1
                0x02, 0x00, // gyroZ
                0x00, 0x80, // accelX = -32768
                0xFF, 0x7F, // accelY = 32767
                0x00, 0x00, // accelZ
                0xDD, 0xCC, 0xBB, 0xAA // timestampDeltaUs LE
            ]
        )
    }

    // MARK: - MSG_BATTERY (0x000B)

    func testBatteryPayloadPinsTheThreeByteLayout() {
        XCTAssertEqual(
            [UInt8](Encoders.batteryPayload(controllerIndex: 2, level: 87, status: .charging)),
            [2, 87, 2]
        )
        // Status-only readers send level = 0xFF (percentage unknown).
        XCTAssertEqual(
            [UInt8](Encoders.batteryPayload(
                controllerIndex: 0,
                level: ProtocolConstants.batteryLevelUnknown,
                status: .wired
            )),
            [0, 0xFF, 4]
        )
    }

    // MARK: - MSG_TOUCHPAD (0x000C) — the protocol-1 16-byte layout

    func testTouchpadPayloadPinsTheSixteenByteLayoutWithTrailingEventTime() {
        let payload = Encoders.touchpadPayload(
            controllerIndex: 5,
            finger0Active: true,
            finger0Id: 7,
            finger0X: 0x1234,
            finger0Y: -2,
            finger1Active: false,
            finger1Id: 9,
            finger1X: 100,
            finger1Y: -100,
            buttonPressed: true,
            eventTimeMs: 0x0102_0304
        )
        XCTAssertEqual(payload.count, 1 + ProtocolConstants.touchpadPayloadBytes)
        XCTAssertEqual(payload.count, 16)
        XCTAssertEqual(
            [UInt8](payload),
            [
                5, // ctrlIdx
                0x05, // flags: f0 active (b0) + button (b2)
                7, // f0 id
                0x34, 0x12, // f0 x LE
                0xFE, 0xFF, // f0 y = -2
                9, // f1 id
                0x64, 0x00, // f1 x = 100
                0x9C, 0xFF, // f1 y = -100
                0x04, 0x03, 0x02, 0x01 // eventTimeMs u32 LE @ offset 12
            ]
        )
    }

    func testTouchpadFlagsBitsAreFinger0Finger1Button() {
        func flags(_ f0: Bool, _ f1: Bool, _ button: Bool) -> UInt8 {
            let payload = Encoders.touchpadPayload(
                controllerIndex: 0,
                finger0Active: f0,
                finger0Id: 0,
                finger0X: 0,
                finger0Y: 0,
                finger1Active: f1,
                finger1Id: 0,
                finger1X: 0,
                finger1Y: 0,
                buttonPressed: button,
                eventTimeMs: 0
            )
            return payload[1]
        }
        XCTAssertEqual(flags(false, false, false), 0x00)
        XCTAssertEqual(flags(true, false, false), 0x01)
        XCTAssertEqual(flags(false, true, false), 0x02)
        XCTAssertEqual(flags(false, false, true), 0x04)
        XCTAssertEqual(flags(true, true, true), 0x07)
    }

    func testTouchpadEventTimeRidesAtOffsetTwelveLittleEndian() {
        let payload = Encoders.touchpadPayload(
            controllerIndex: 0,
            finger0Active: false,
            finger0Id: 0,
            finger0X: 0,
            finger0Y: 0,
            finger1Active: false,
            finger1Id: 0,
            finger1X: 0,
            finger1Y: 0,
            buttonPressed: false,
            eventTimeMs: 0xDEAD_BEEF
        )
        // Length gate BEFORE the subscript: a short-encoder regression must
        // fail with a diagnostic, not trap the whole test process (the
        // sibling test above pins count == 16 as the layout contract).
        guard payload.count == 16 else {
            return XCTFail("expected a 16-byte touchpad payload, got \(payload.count)")
        }
        XCTAssertEqual([UInt8](payload[12 ... 15]), [0xEF, 0xBE, 0xAD, 0xDE])
    }

    // MARK: - MSG_HEARTBEAT_ACK (0x0003) parse

    func testHeartbeatAckParsesTheEnrichedBigEndianFields() {
        let ack = HeartbeatAck.parse(Data([1, 3, 0x00, 0x04, 0x80, 0x01]))
        XCTAssertEqual(
            ack,
            HeartbeatAck(backendAvailable: true, activeCount: 3, epoch: 4, bitmap: 0x8001)
        )
        // backendAvailable is any-nonzero.
        XCTAssertEqual(HeartbeatAck.parse(Data([0, 0, 0xAB, 0xCD, 0x12, 0x34]))?.backendAvailable, false)
        XCTAssertEqual(HeartbeatAck.parse(Data([2, 0, 0xAB, 0xCD, 0x12, 0x34]))?.backendAvailable, true)
        XCTAssertEqual(HeartbeatAck.parse(Data([0, 0, 0xAB, 0xCD, 0x12, 0x34]))?.epoch, 0xABCD)
        XCTAssertEqual(HeartbeatAck.parse(Data([0, 0, 0xAB, 0xCD, 0x12, 0x34]))?.bitmap, 0x1234)
    }

    func testHeartbeatAckToleratesTrailingBytesButRejectsShortPayloads() {
        // A bare ack from a pre-protocol-1 server is shorter → nil (liveness
        // still counts on the caller side; reconcile doesn't).
        XCTAssertNil(HeartbeatAck.parse(Data()))
        XCTAssertNil(HeartbeatAck.parse(Data([1, 3, 0x00, 0x04, 0x80])))
        // Trailing extension bytes from a newer server still parse.
        XCTAssertNotNil(HeartbeatAck.parse(Data([1, 3, 0x00, 0x04, 0x80, 0x01, 0xEE])))
    }

    // MARK: - MSG_RUMBLE (0x0009) parse

    func testRumbleParsesTheFixedSevenByteBigEndianPayload() {
        let rumble = RumbleCommand.parse(Data([1, 0x12, 0x34, 0x56, 0x78, 0x01, 0xF4]))
        XCTAssertEqual(
            rumble,
            RumbleCommand(controllerIndex: 1, strongMagnitude: 0x1234, weakMagnitude: 0x5678, durationMs: 500)
        )
        XCTAssertNil(RumbleCommand.parse(Data([1, 0x12, 0x34, 0x56, 0x78, 0x01])))
        XCTAssertNil(RumbleCommand.parse(Data()))
    }

    // MARK: - MSG_LIGHTBAR (0x000D) parse

    func testLightbarParsesTheFourBytePayload() {
        XCTAssertEqual(
            LightbarCommand.parse(Data([0, 10, 20, 30])),
            LightbarCommand(controllerIndex: 0, r: 10, g: 20, b: 30)
        )
        XCTAssertNil(LightbarCommand.parse(Data([0, 10, 20])))
        XCTAssertNil(LightbarCommand.parse(Data()))
    }
}
