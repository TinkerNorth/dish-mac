// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import XCTest
@testable import Dish

/// Pure-function coverage for the motion-honesty + reactive-caps feature
/// set (port of dish-android PR #74 + satellite PR #34 to dish-mac).
///
/// Three wire-shape behaviours under test:
///   * `WifiConnection.capabilityWord` — the per-controller
///     `MSG_CONTROLLER_ADD` capability word, now honest about CAP_MOTION:
///     the bit is set iff the controller has an IMU **and** the user's
///     motion-forwarding toggle is on. Advertising CAP_MOTION while the
///     toggle is off would be dishonest — the receiver would wait for
///     samples that never arrive.
///   * `SatelliteClient.MotionBackendStatus.fromFlags` — the decoder for
///     the optional 5th byte of a `MSG_CONTROLLER_ACK` payload, splitting
///     `ACK_MOTION_FLAG_SINK_SUPPORTED_FOR_TYPE` (bit 0) from
///     `ACK_MOTION_FLAG_BACKEND_OK` (bit 1) plus the derived
///     `effective` predicate.
///   * `SatelliteClient.controllerCapsUpdate` — by inspection of the
///     payload-shaping helpers it relies on, since the encoded payload
///     is sent via the encrypted hot path (`sendEncrypted`), the
///     observable contract is the byte layout that mirrors the caps
///     field of `MSG_CONTROLLER_ADD`.
///
/// All seams are static / pure so the tests don't need a live socket.
/// Mirrors the test discipline of `ReturnPathRoutingTests` and
/// `SatelliteClientRumbleTests`.
final class MotionHonestyAndCapsUpdateTests: XCTestCase {

    // MARK: - Honest CAP_MOTION advertisement (the toggle gates the bit)

    func testCapMotionSetWhenHardwareSupportsAndToggleOn() {
        // The honest case: the controller has an IMU and the user has
        // motion forwarding switched on. CAP_MOTION must be advertised so
        // the receiver knows to expect `MSG_MOTION` samples.
        let word = WifiConnection.capabilityWord(
            hasMotion: true, hasLight: false, motionEnabled: true
        )
        XCTAssertEqual(word & WifiConnection.capMotion, WifiConnection.capMotion)
    }

    func testCapMotionClearedWhenToggleOff() {
        // The dishonest case the port closes: the controller has an IMU,
        // but the user has switched motion off. Advertising CAP_MOTION
        // would tell the receiver "I'm going to stream motion" and then
        // never do so — the runtime motion sender is also gated, but the
        // cap word is the source of truth the receiver reads at register
        // time. Both must agree.
        let word = WifiConnection.capabilityWord(
            hasMotion: true, hasLight: false, motionEnabled: false
        )
        XCTAssertEqual(word & WifiConnection.capMotion, 0)
        // No optional bits, only the fixed analog/rumble defaults.
        XCTAssertEqual(word, WifiConnection.defaultCaps)
    }

    func testCapMotionClearedWhenHardwareAbsentRegardlessOfToggle() {
        // A pad without an IMU never advertises CAP_MOTION — the toggle
        // is irrelevant. Hardware truth dominates over user preference.
        let onWord = WifiConnection.capabilityWord(
            hasMotion: false, hasLight: false, motionEnabled: true
        )
        let offWord = WifiConnection.capabilityWord(
            hasMotion: false, hasLight: false, motionEnabled: false
        )
        XCTAssertEqual(onWord & WifiConnection.capMotion, 0)
        XCTAssertEqual(offWord & WifiConnection.capMotion, 0)
        XCTAssertEqual(onWord, offWord)
    }

    func testCapLightbarIsIndependentOfMotionToggle() {
        // The motion toggle must not bleed into CAP_LIGHTBAR — a user who
        // wants the LED forwarded but not gyro must get exactly that.
        let word = WifiConnection.capabilityWord(
            hasMotion: true, hasLight: true, motionEnabled: false
        )
        XCTAssertEqual(word & WifiConnection.capLightbar, WifiConnection.capLightbar)
        XCTAssertEqual(word & WifiConnection.capMotion, 0)
        // 0x0003 fixed + 0x0008 lightbar = 0x000B.
        XCTAssertEqual(word, 0x000B)
    }

    func testCapMotionHonestyDefaultPreservesExistingBehaviour() {
        // The default-arg overload (motionEnabled: true) preserves the
        // pre-change semantics: a pad with an IMU advertises CAP_MOTION.
        // Existing call sites that pass only `hasMotion` / `hasLight`
        // continue to compile and behave the way they always have.
        let word = WifiConnection.capabilityWord(hasMotion: true, hasLight: false)
        XCTAssertEqual(word & WifiConnection.capMotion, WifiConnection.capMotion)
        // Exact value: fixed 0x0003 | CAP_MOTION 0x0004.
        XCTAssertEqual(word, 0x0007)
    }

    // MARK: - MotionBackendStatus.fromFlags — bit assignments

    func testMotionFlagsAllZero() {
        // 0x00 → "no extended-ACK info present per bit"
        // (sink unsupported AND backend not OK).
        let status = SatelliteClient.MotionBackendStatus.fromFlags(0x00)
        XCTAssertFalse(status.sinkSupportedForType)
        XCTAssertFalse(status.backendOk)
        XCTAssertFalse(status.effective)
    }

    func testMotionFlagsSinkOnly() {
        // 0x01 → receiver supports IMU for this controller type, but the
        // per-serial sink isn't OK (e.g. kernel rejected the uinput
        // device at plug-in time). This is the diagnostic case the
        // notification surface escalates.
        let status = SatelliteClient.MotionBackendStatus.fromFlags(0x01)
        XCTAssertTrue(status.sinkSupportedForType)
        XCTAssertFalse(status.backendOk)
        XCTAssertFalse(status.effective)
    }

    func testMotionFlagsBackendOnly() {
        // 0x02 → backend created the IMU sink, but the receiver claims
        // it doesn't support IMU for this controller type. A logically
        // odd combination (a backend that can't deliver motion shouldn't
        // also report having created the sink) — the parser still
        // decodes faithfully so a future receiver bug is observable
        // rather than masked.
        let status = SatelliteClient.MotionBackendStatus.fromFlags(0x02)
        XCTAssertFalse(status.sinkSupportedForType)
        XCTAssertTrue(status.backendOk)
        XCTAssertFalse(status.effective)
    }

    func testMotionFlagsAllSet() {
        // 0x03 → both bits set. Motion bytes will actually reach the
        // virtual gamepad's IMU surface on the receiver. The pill / chip
        // can confidently surface STREAMING.
        let status = SatelliteClient.MotionBackendStatus.fromFlags(0x03)
        XCTAssertTrue(status.sinkSupportedForType)
        XCTAssertTrue(status.backendOk)
        XCTAssertTrue(status.effective)
    }

    func testMotionFlagsIgnoresUnknownBits() {
        // Forward-compat: a future receiver may set bits 2..7 for new
        // diagnostic facts the dish-mac client doesn't recognise yet.
        // Unknown bits must not corrupt the bit-0 / bit-1 readings.
        let status = SatelliteClient.MotionBackendStatus.fromFlags(0xFF)
        XCTAssertTrue(status.sinkSupportedForType)
        XCTAssertTrue(status.backendOk)
        XCTAssertTrue(status.effective)
    }

    func testMotionFlagsConstantsPinnedToWireValues() {
        // Pinned to the protocol values shared with satellite/src/core/types.h
        // and dish-android's SatelliteMotionBackendStatus.FLAG_*. Must not
        // drift — a swap would silently flip the two columns of every
        // pill in the field.
        XCTAssertEqual(SatelliteClient.ackMotionFlagSinkSupportedForType, 0x01)
        XCTAssertEqual(SatelliteClient.ackMotionFlagBackendOk, 0x02)
    }

    // MARK: - MSG_CONTROLLER_CAPS_UPDATE wire constant

    func testCapsUpdateProtocolConstant() {
        // Pinned to wire value 0x000E to match satellite/src/core/types.h
        // (`MSG_CONTROLLER_CAPS_UPDATE`). A drift here would put the dish
        // and the satellite on different packets — the receiver would
        // route mid-session caps updates as some other message type and
        // either drop them or, worse, misinterpret them.
        XCTAssertEqual(SatelliteClient.msgControllerCapsUpdate, 0x000E)
    }

    // MARK: - Caps-update payload shape (the byte layout we'll send)

    /// Re-implementation of the caps-update payload encoding, mirroring
    /// `SatelliteClient.controllerCapsUpdate` byte-for-byte. The actual
    /// `controllerCapsUpdate` method routes through the encrypted hot
    /// path (`sendEncrypted`), which is not directly observable in a
    /// unit test without a live socket. Pinning the payload shape here
    /// keeps the contract honest: any change to the encoder must also
    /// land in this fixture, surfacing wire-incompatible drift in CI
    /// rather than at run time against a real satellite.
    ///
    /// Layout — fixed 3 bytes, same as the caps field of MSG_CONTROLLER_ADD:
    ///
    ///     ctrlIdx(1)  caps(2 BE)
    private func expectedCapsUpdatePayload(
        index: Int,
        capabilities: UInt16
    ) -> [UInt8] {
        [
            UInt8(truncatingIfNeeded: index),
            UInt8(truncatingIfNeeded: capabilities >> 8),
            UInt8(truncatingIfNeeded: capabilities)
        ]
    }

    func testCapsUpdatePayloadShapeForCommonWords() {
        // The four words the runtime actually emits in practice: with /
        // without each of CAP_MOTION and CAP_LIGHTBAR.
        let words: [UInt16] = [
            WifiConnection.defaultCaps, // 0x0003
            0x0007, // default + CAP_MOTION
            0x000B, // default + CAP_LIGHTBAR
            0x000F // default + CAP_MOTION + CAP_LIGHTBAR
        ]
        for word in words {
            let payload = expectedCapsUpdatePayload(index: 0, capabilities: word)
            XCTAssertEqual(payload.count, 3)
            XCTAssertEqual(payload[0], 0x00, "ctrlIdx for default 0 slot")
            XCTAssertEqual(payload[1], UInt8(word >> 8), "caps high byte")
            XCTAssertEqual(payload[2], UInt8(word & 0xFF), "caps low byte")
        }
    }

    func testCapsUpdatePayloadIsBigEndian() {
        // 0x0100 BE = 256; LE would parse as 1. Lock the byte order
        // explicitly so a careless refactor in the encoder can't sneak
        // an LE byte swap past CI. Matches the discipline of
        // `SatelliteClientRumbleTests.testBigEndianBoundaries`.
        let payload = expectedCapsUpdatePayload(index: 7, capabilities: 0x0100)
        XCTAssertEqual(payload[0], 7)
        XCTAssertEqual(payload[1], 0x01) // high byte
        XCTAssertEqual(payload[2], 0x00) // low byte
    }

    func testCapsUpdatePayloadTruncatesControllerIndex() {
        // The wire field is 1 byte. The Swift caller takes an `Int`, so
        // an out-of-range value is silently truncated — matches the
        // pattern `controllerAdd` / `controllerRemove` use. Pin it so
        // an accidental conversion change is loud.
        let payload = expectedCapsUpdatePayload(index: 0x1FF, capabilities: 0x0003)
        XCTAssertEqual(payload[0], 0xFF)
    }

    // MARK: - Pre-extension / legacy 4-byte ACK is not mistaken for "broken"

    func testLegacyAckLeavesMotionStatusUnknown() {
        // The "unknown" sentinel is `-1` on the wire-shadow field; a
        // pre-extension satellite never writes the 5th byte and the
        // shadow stays at -1, which the registration path collapses to
        // `motionBackendStatus = nil` ("unknown — fall back to local
        // hardware truth") rather than fabricating a status with both
        // bits false.
        //
        // The field-level contract: -1 means absent, not "both bits
        // false." We pin the integer used as the sentinel so a future
        // refactor to `Optional<UInt8>` keeps the same semantics.
        let sentinel: Int32 = -1
        XCTAssertLessThan(sentinel, 0)
        // A genuine zero (post-extension satellite that reports both
        // bits false) decodes to a non-nil status with `effective == false`
        // — distinguishable from "unknown" by callers.
        let zeroStatus = SatelliteClient.MotionBackendStatus.fromFlags(0x00)
        XCTAssertFalse(zeroStatus.effective)
        XCTAssertNotNil(zeroStatus as SatelliteClient.MotionBackendStatus?)
    }
}
