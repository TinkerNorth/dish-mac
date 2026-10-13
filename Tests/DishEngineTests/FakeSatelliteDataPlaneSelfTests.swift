// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import CryptoKit
import Foundation
import Security
import XCTest

// MARK: - UDP data plane (scripted raw client)

final class FakeSatelliteDataPlaneSelfTests: XCTestCase {

    func testGoldenPathPairPutInputAckCloseNotify() async throws {
        let harness = try await ScriptedHarness.boot(controllers: [ds4Descriptor], hostFeatures: ["mouseControl": true])
        defer { harness.shutdown() }
        let satellite = harness.satellite
        // Heartbeat (counter 1 — counters start at 1) → enriched ack.
        try harness.sendUp(FakeSatelliteOpcode.heartbeat, counter: 1)
        let ack = try XCTUnwrap(harness.awaitDown())
        XCTAssertEqual(ack.opcode, FakeSatelliteOpcode.heartbeatAck)
        XCTAssertEqual(ack.counter, 1) // server down-counter starts at 1 too
        XCTAssertEqual(ack.payload.count, 6)
        XCTAssertEqual(ack.payload[ack.payload.startIndex], 1) // backendAvailable
        XCTAssertEqual(ack.payload[ack.payload.startIndex + 1], 1) // active count
        XCTAssertEqual(FakeSatelliteCrypto.readBE16(ack.payload, at: 2), satellite.epoch)
        XCTAssertEqual(FakeSatelliteCrypto.readBE16(ack.payload, at: 4), 0b1) // slot 0 bitmap
        XCTAssertEqual(satellite.heartbeatCount, 1)
        // Encrypted INPUT decrypts server-side into a typed record.
        let report = Data((0 ..< 12).map { UInt8($0) })
        try harness.sendUp(FakeSatelliteOpcode.input, Data([0]) + report, counter: 2)
        let input = try XCTUnwrap(satellite.awaitFrame(opcode: FakeSatelliteOpcode.input))
        XCTAssertEqual(input.counter, 2)
        XCTAssertEqual(input.detail, .input(ctrlIdx: 0, report: report))
        // 16-byte touchpad frame; eventTimeMs u32 LE at offset 12.
        let touchPayload = Data([0, 0b101, 7]) + le16(320) + le16(-471) + Data([9]) + le16(0) + le16(0) + le32(0xDEAD_BEEF)
        XCTAssertEqual(touchPayload.count, 16)
        try harness.sendUp(FakeSatelliteOpcode.touchpad, touchPayload, counter: 3)
        let touch = try XCTUnwrap(satellite.awaitFrame(opcode: FakeSatelliteOpcode.touchpad))
        guard case let .touchpad(frame) = touch.detail else {
            return XCTFail("expected a typed touchpad frame, got \(touch.detail)")
        }
        XCTAssertEqual(frame.flags, 0b101)
        XCTAssertEqual(frame.finger0Id, 7)
        XCTAssertEqual(frame.finger0X, 320)
        XCTAssertEqual(frame.finger0Y, -471)
        XCTAssertEqual(frame.eventTimeMs, 0xDEAD_BEEF)
        // Server-initiated close-notify, encrypted, reason kicked.
        XCTAssertTrue(satellite.sendSessionClose(.kicked))
        let close = try XCTUnwrap(harness.awaitDown())
        XCTAssertEqual(close.opcode, FakeSatelliteOpcode.sessionClose)
        XCTAssertEqual(close.counter, 2)
        XCTAssertEqual(close.payload, Data([FakeSatelliteCloseReason.kicked.rawValue]))
    }

    func testReplayGuardDropsNonMonotonicCounters() async throws {
        let harness = try await ScriptedHarness.boot(controllers: [ds4Descriptor])
        defer { harness.shutdown() }
        let report = Data(count: 12)
        let send: (UInt32) throws -> Void = { counter in
            try harness.sendUp(FakeSatelliteOpcode.input, Data([0]) + report, counter: counter)
        }
        try send(1)
        XCTAssertTrue(harness.satellite.awaitFrameCount(opcode: FakeSatelliteOpcode.input, atLeast: 1))
        try send(1) // exact replay
        XCTAssertTrue(harness.satellite.awaitReplayDrops(atLeast: 1))
        try send(1) // replayed again
        XCTAssertTrue(harness.satellite.awaitReplayDrops(atLeast: 2))
        try send(3) // gaps are fine — monotonicity is the only rule
        XCTAssertTrue(harness.satellite.awaitFrameCount(opcode: FakeSatelliteOpcode.input, atLeast: 2))
        try send(2) // older than the watermark → dropped
        XCTAssertTrue(harness.satellite.awaitReplayDrops(atLeast: 3))
        XCTAssertEqual(harness.satellite.frames.filter { $0.opcode == FakeSatelliteOpcode.input }.count, 2)
    }

    func testWrongDirectionWrongAadAndUnknownTokenRejected() async throws {
        let harness = try await ScriptedHarness.boot(controllers: [ds4Descriptor])
        defer { harness.shutdown() }
        let context = harness.context
        // Wrong direction byte in the nonce.
        try harness.sendUp(FakeSatelliteOpcode.heartbeat, counter: 1, direction: .serverToClient)
        XCTAssertTrue(harness.satellite.awaitAuthFailDrops(atLeast: 1))
        // AAD sealed over a token that differs from the cleartext header.
        try harness.sendUp(FakeSatelliteOpcode.heartbeat, counter: 2, aadToken: context.token &+ 1)
        XCTAssertTrue(harness.satellite.awaitAuthFailDrops(atLeast: 2))
        // Unknown token in the header never reaches the AEAD.
        try harness.sendUp(FakeSatelliteOpcode.heartbeat, counter: 1, token: context.token &+ 99)
        XCTAssertTrue(harness.satellite.awaitUnknownTokenDrops(atLeast: 1))
        XCTAssertEqual(harness.satellite.heartbeatCount, 0)
        XCTAssertTrue(harness.satellite.frames.isEmpty)
    }

    func testEnrichedAckOverrides() async throws {
        let harness = try await ScriptedHarness.boot(controllers: [ds4Descriptor])
        defer { harness.shutdown() }
        let satellite = harness.satellite
        satellite.ackEpochOverride = 7
        satellite.ackBitmapOverride = 0b0000_0000_0000_0101
        satellite.ackCountOverride = 9
        satellite.ackBackendAvailableOverride = false
        try harness.sendUp(FakeSatelliteOpcode.heartbeat, counter: 1)
        let overridden = try XCTUnwrap(harness.awaitDown())
        XCTAssertEqual(Array(overridden.payload), [0, 9, 0, 7, 0, 5])
        satellite.ackEpochOverride = nil
        satellite.ackBitmapOverride = nil
        satellite.ackCountOverride = nil
        satellite.ackBackendAvailableOverride = nil
        try harness.sendUp(FakeSatelliteOpcode.heartbeat, counter: 2)
        let derived = try XCTUnwrap(harness.awaitDown())
        XCTAssertEqual(derived.payload[derived.payload.startIndex], 1)
        XCTAssertEqual(derived.payload[derived.payload.startIndex + 1], 1)
        XCTAssertEqual(FakeSatelliteCrypto.readBE16(derived.payload, at: 2), satellite.epoch)
        XCTAssertEqual(FakeSatelliteCrypto.readBE16(derived.payload, at: 4), 0b1)
    }

    func testRumbleAndLightbarInjection() async throws {
        let harness = try await ScriptedHarness.boot(controllers: [ds4Descriptor])
        defer { harness.shutdown() }
        let satellite = harness.satellite
        // No uplink yet → no reply path → injection reports failure.
        XCTAssertFalse(satellite.injectRumble(ctrlIdx: 0, strong: 1, weak: 1, durationMs: 1))
        try harness.sendUp(FakeSatelliteOpcode.heartbeat, counter: 1)
        _ = try XCTUnwrap(harness.awaitDown()) // consume the heartbeat ack
        XCTAssertTrue(satellite.injectRumble(ctrlIdx: 0, strong: 0xFFFF, weak: 0x1234, durationMs: 500))
        let rumble = try XCTUnwrap(harness.awaitDown())
        XCTAssertEqual(rumble.opcode, FakeSatelliteOpcode.rumble)
        XCTAssertEqual(Array(rumble.payload), [0, 0xFF, 0xFF, 0x12, 0x34, 0x01, 0xF4])
        XCTAssertTrue(satellite.injectLightbar(ctrlIdx: 0, red: 1, green: 2, blue: 3))
        let lightbar = try XCTUnwrap(harness.awaitDown())
        XCTAssertEqual(lightbar.opcode, FakeSatelliteOpcode.lightbar)
        XCTAssertEqual(Array(lightbar.payload), [0, 1, 2, 3])
        XCTAssertEqual(lightbar.counter, 3) // down counters stay monotonic
    }
}
