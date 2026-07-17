// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// Pins the protocol-1 constants to the authoritative values in
// satellite/src/core/types.h (contract §UDP messages, §Liveness, §Crypto).
// The deleted topology opcodes 0x0004–0x0008 / 0x000E have NO constant — a
// stray reference fails to compile, which is the point.

import DishCore
import XCTest

final class ProtocolConstantsTests: XCTestCase {

    func testProtocolVersionIsOne() {
        XCTAssertEqual(ProtocolConstants.protocolVersion, 1)
    }

    func testOpcodeValuesMatchSatelliteTypesHeader() {
        XCTAssertEqual(ProtocolConstants.msgInput, 0x0001)
        XCTAssertEqual(ProtocolConstants.msgHeartbeat, 0x0002)
        XCTAssertEqual(ProtocolConstants.msgHeartbeatAck, 0x0003)
        XCTAssertEqual(ProtocolConstants.msgRumble, 0x0009)
        XCTAssertEqual(ProtocolConstants.msgMotion, 0x000A)
        XCTAssertEqual(ProtocolConstants.msgBattery, 0x000B)
        XCTAssertEqual(ProtocolConstants.msgTouchpad, 0x000C)
        XCTAssertEqual(ProtocolConstants.msgLightbar, 0x000D)
        XCTAssertEqual(ProtocolConstants.msgSessionClose, 0x000F)
    }

    func testWireSizesMatchContract() {
        XCTAssertEqual(ProtocolConstants.headerSize, 8)
        XCTAssertEqual(ProtocolConstants.innerHeaderSize, 4)
        XCTAssertEqual(ProtocolConstants.authTagSize, 16)
        XCTAssertEqual(ProtocolConstants.cryptoKeySize, 32)
        XCTAssertEqual(ProtocolConstants.cryptoNonceSize, 12)
        XCTAssertEqual(ProtocolConstants.sessionSaltSize, 8)
        XCTAssertEqual(ProtocolConstants.inputPayloadBytes, 13)
        XCTAssertEqual(ProtocolConstants.motionPayloadBytes, 17)
        XCTAssertEqual(ProtocolConstants.batteryPayloadBytes, 3)
        // 15 post-ctrlIdx bytes = 16-byte inner payload; the trailing
        // eventTimeMs u32 is the protocol-1 addition (12-byte bodies dropped).
        XCTAssertEqual(ProtocolConstants.touchpadPayloadBytes, 15)
        XCTAssertEqual(ProtocolConstants.heartbeatAckPayloadBytes, 6)
        XCTAssertEqual(ProtocolConstants.rumblePayloadBytes, 7)
        XCTAssertEqual(ProtocolConstants.lightbarPayloadBytes, 4)
    }

    func testLivenessAndLatencyThresholds() {
        XCTAssertEqual(ProtocolConstants.heartbeatIntervalMs, 2000)
        XCTAssertEqual(ProtocolConstants.heartbeatMissNotResponding, 2)
        XCTAssertEqual(ProtocolConstants.heartbeatMissMax, 5)
        XCTAssertEqual(ProtocolConstants.latencyWindowCapacity, 64)
        XCTAssertEqual(ProtocolConstants.counterRepushThreshold, 0xF000_0000)
    }

    func testCapabilityBitsAndControllerTypes() {
        XCTAssertEqual(ProtocolConstants.capAnalogTriggers, 0x0001)
        XCTAssertEqual(ProtocolConstants.capRumble, 0x0002)
        XCTAssertEqual(ProtocolConstants.capMotion, 0x0004)
        XCTAssertEqual(ProtocolConstants.capLightbar, 0x0008)
        XCTAssertEqual(ProtocolConstants.controllerTypeXbox, 0)
        XCTAssertEqual(ProtocolConstants.controllerTypePlayStation, 1)
        XCTAssertEqual(ProtocolConstants.maxControllersPerConnection, 16)
    }

    func testBatteryWireConstants() {
        XCTAssertEqual(BatteryStatus.unknown.rawValue, 0)
        XCTAssertEqual(BatteryStatus.discharging.rawValue, 1)
        XCTAssertEqual(BatteryStatus.charging.rawValue, 2)
        XCTAssertEqual(BatteryStatus.full.rawValue, 3)
        XCTAssertEqual(BatteryStatus.wired.rawValue, 4)
        XCTAssertEqual(ProtocolConstants.batteryLevelUnknown, 0xFF)
    }

    func testApplyResultWireStringsRoundTrip() {
        // Protocol constants, never localized (contract §Session).
        let pairs: [(ApplyResult, String)] = [
            (.ok, "ok"),
            (.noSlots, "noSlots"),
            (.pluginFailed, "pluginFailed"),
            (.replugFailed, "replugFailed"),
            (.backendUnavailable, "backendUnavailable"),
            (.invalidType, "invalidType"),
            (.invalidIndex, "invalidIndex")
        ]
        for (result, name) in pairs {
            XCTAssertEqual(result.wireName, name)
            XCTAssertEqual(ApplyResult(wireName: name), result)
        }
        // A result string a newer server invented maps to .unknown, not a guess.
        XCTAssertEqual(ApplyResult(wireName: "hologramFailed"), .unknown)
    }

    func testApplyResultLiveness() {
        // ok and replugFailed keep streams flowing (previous pad still in
        // force); everything else means the slot is not plugged.
        XCTAssertTrue(ApplyResult.ok.slotIsLive)
        XCTAssertTrue(ApplyResult.replugFailed.slotIsLive)
        XCTAssertFalse(ApplyResult.noSlots.slotIsLive)
        XCTAssertFalse(ApplyResult.pluginFailed.slotIsLive)
        XCTAssertFalse(ApplyResult.backendUnavailable.slotIsLive)
        XCTAssertFalse(ApplyResult.invalidType.slotIsLive)
        XCTAssertFalse(ApplyResult.invalidIndex.slotIsLive)
        XCTAssertFalse(ApplyResult.unknown.slotIsLive)
    }

    func testTouchpadModeWireStrings() {
        XCTAssertEqual(TouchpadMode.ds4.wireName, "ds4")
        XCTAssertEqual(TouchpadMode.mouse.wireName, "mouse")
        XCTAssertEqual(TouchpadMode.off.wireName, "off")
        XCTAssertEqual(TouchpadMode(wireName: "ds4"), .ds4)
        XCTAssertEqual(TouchpadMode(wireName: "mouse"), .mouse)
        XCTAssertEqual(TouchpadMode(wireName: "off"), .off)
        // Unknown modes gate to off — the server's default too.
        XCTAssertEqual(TouchpadMode(wireName: "hover"), .off)
    }

    func testAuthCodesAndHostDenyReasons() {
        XCTAssertEqual(ProtocolConstants.authCodeNotPaired, "NOT_PAIRED")
        XCTAssertEqual(ProtocolConstants.authCodeBadProof, "BAD_PROOF")
        XCTAssertEqual(ProtocolConstants.hostDenyNotSupported, "notSupported")
        XCTAssertEqual(ProtocolConstants.hostDenyBackendUnavailable, "backendUnavailable")
        XCTAssertEqual(ProtocolConstants.hostDenyDenied, "denied")
    }
}
