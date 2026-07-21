// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import XCTest
@testable import Dish

/// Coverage for the light-bar return path:
///
///   * `ReturnPathRouting` — the pure decision layer that gates `MSG_RUMBLE`
///     vibration and `MSG_LIGHTBAR` colour independently, so the Light bar
///     setting and the Rumble setting never bleed into each other.
///   * `WifiConnection.capabilityWord` — the per-controller descriptor `caps`
///     word (protocol-1: rides the REST descriptor, not a UDP opcode),
///     advertising `CAP_MOTION` iff the bound controller has an IMU and
///     `CAP_LIGHTBAR` iff it has an addressable RGB light.
///
/// Both are exercised as pure functions: no socket, no live `GCController`.
final class ReturnPathRoutingTests: XCTestCase {

    // MARK: - Fixtures

    private func flags(rumble: Bool, lightbar: Bool) -> ForwardingFlags {
        ForwardingFlags(motion: true, touchpad: true, rumble: rumble, lightbar: lightbar)
    }

    // MARK: - MSG_RUMBLE routing: vibration is gated on the Rumble toggle

    func testRumbleVibratesWhenRumbleOn() {
        XCTAssertTrue(ReturnPathRouting.shouldVibrate(flags: flags(rumble: true, lightbar: true)))
    }

    func testRumbleDoesNotVibrateWhenRumbleOff() {
        XCTAssertFalse(ReturnPathRouting.shouldVibrate(flags: flags(rumble: false, lightbar: true)))
    }

    func testRumbleVibrationIndependentOfLightbarToggle() {
        // The Rumble decision never consults the Light bar setting.
        XCTAssertTrue(ReturnPathRouting.shouldVibrate(flags: flags(rumble: true, lightbar: false)))
        XCTAssertFalse(ReturnPathRouting.shouldVibrate(flags: flags(rumble: false, lightbar: true)))
    }

    // MARK: - MSG_LIGHTBAR: gated solely on the Light bar setting

    func testLightbarMessageAppliedWhenLightbarOn() {
        let msg = LightbarCommand(controllerIndex: 0, r: 0x11, g: 0x22, b: 0x33)
        XCTAssertTrue(
            ReturnPathRouting.shouldApply(lightbar: msg, flags: flags(rumble: true, lightbar: true))
        )
    }

    func testLightbarMessageSuppressedWhenLightbarOff() {
        let msg = LightbarCommand(controllerIndex: 0, r: 0x11, g: 0x22, b: 0x33)
        XCTAssertFalse(
            ReturnPathRouting.shouldApply(lightbar: msg, flags: flags(rumble: true, lightbar: false))
        )
    }

    func testLightbarMessageIndependentOfRumbleToggle() {
        // The light-bar path does not consult the Rumble toggle: rumble off
        // must not disable MSG_LIGHTBAR.
        let msg = LightbarCommand(controllerIndex: 0, r: 1, g: 2, b: 3)
        XCTAssertTrue(
            ReturnPathRouting.shouldApply(lightbar: msg, flags: flags(rumble: false, lightbar: true))
        )
        XCTAssertFalse(
            ReturnPathRouting.shouldApply(lightbar: msg, flags: flags(rumble: false, lightbar: false))
        )
    }

    // MARK: - CAP_MOTION / CAP_LIGHTBAR capability word (descriptor caps)

    func testCapabilityWordWithLightSetsCapLightbar() {
        let word = WifiConnection.capabilityWord(hasMotion: true, hasLight: true)
        // CAP_LIGHTBAR bit present.
        XCTAssertEqual(word & ProtocolConstants.capLightbar, ProtocolConstants.capLightbar)
        // Exact value: fixed 0x0003 | CAP_MOTION 0x0004 | CAP_LIGHTBAR 0x0008.
        XCTAssertEqual(word, 0x000F)
    }

    func testCapabilityWordWithoutLightOmitsCapLightbar() {
        let word = WifiConnection.capabilityWord(hasMotion: true, hasLight: false)
        // CAP_LIGHTBAR bit absent.
        XCTAssertEqual(word & ProtocolConstants.capLightbar, 0)
        // Fixed default + CAP_MOTION only.
        XCTAssertEqual(word, 0x0007)
    }

    func testCapabilityWordWithMotionSetsCapMotion() {
        let word = WifiConnection.capabilityWord(hasMotion: true, hasLight: false)
        XCTAssertEqual(word & ProtocolConstants.capMotion, ProtocolConstants.capMotion)
    }

    func testCapabilityWordWithoutMotionOmitsCapMotion() {
        // A controller with no IMU must NOT advertise CAP_MOTION.
        let word = WifiConnection.capabilityWord(hasMotion: false, hasLight: false)
        XCTAssertEqual(word & ProtocolConstants.capMotion, 0)
        // Exactly the fixed default — no optional bits.
        XCTAssertEqual(word, WifiConnection.defaultCaps)
        XCTAssertEqual(word, 0x0003)
    }

    func testCapabilityWordPreservesFixedBits() {
        // The per-controller CAP_MOTION / CAP_LIGHTBAR bits must be OR'd in
        // *without* disturbing the fixed analog-triggers / rumble bits.
        for hasMotion in [true, false] {
            for hasLight in [true, false] {
                let word = WifiConnection.capabilityWord(
                    hasMotion: hasMotion, hasLight: hasLight
                )
                XCTAssertEqual(
                    word & ProtocolConstants.capAnalogTriggers,
                    ProtocolConstants.capAnalogTriggers,
                    "CAP_ANALOG_TRIGGERS lost"
                )
                XCTAssertEqual(word & ProtocolConstants.capRumble, ProtocolConstants.capRumble, "CAP_RUMBLE lost")
            }
        }
    }

    func testCapabilityWordIsAdvertisedIffControllerHasCapability() {
        // The "iff" the spec calls for: each per-controller bit is set exactly
        // when (and only when) the controller exposes that capability.
        XCTAssertTrue((WifiConnection.capabilityWord(hasMotion: true, hasLight: false) & 0x0004) != 0)
        XCTAssertFalse((WifiConnection.capabilityWord(hasMotion: false, hasLight: false) & 0x0004) != 0)
        XCTAssertTrue((WifiConnection.capabilityWord(hasMotion: false, hasLight: true) & 0x0008) != 0)
        XCTAssertFalse((WifiConnection.capabilityWord(hasMotion: false, hasLight: false) & 0x0008) != 0)
    }

    // MARK: - desiredDescriptor (the declarative-PUT seam)

    @MainActor
    func testDesiredDescriptorNilWithoutBoundSlot() {
        let conn = WifiConnection(
            id: "wifi:127.0.0.1:9876",
            server: DiscoveredServer(name: "S", ip: "127.0.0.1", udpPort: 9876, pairPort: 9443, httpPort: 9443)
        )
        XCTAssertNil(conn.desiredDescriptor, "zero-controller session: no descriptor")
    }

    @MainActor
    func testDesiredDescriptorReflectsBoundSlotCapabilities() {
        let conn = WifiConnection(
            id: "wifi:127.0.0.1:9876",
            server: DiscoveredServer(name: "S", ip: "127.0.0.1", udpPort: 9876, pairPort: 9443, httpPort: 9443)
        )
        conn.attachSlot("slot-a", controllerType: 0, hasMotion: true, hasLight: true)
        let descriptor = conn.desiredDescriptor
        XCTAssertEqual(descriptor?.ctrlIdx, 0)
        XCTAssertEqual(descriptor?.type, ProtocolConstants.controllerTypeXbox)
        XCTAssertEqual(descriptor?.caps, 0x000F)
        XCTAssertEqual(descriptor?.touchpadMode, .off)

        conn.detachSlot()
        XCTAssertNil(conn.desiredDescriptor, "detach empties the desired set")
    }
}
