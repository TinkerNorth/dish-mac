// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import XCTest
@testable import Dish

/// Coverage for the light-bar return path:
///
///   * `ReturnPathRouting` — the pure decision layer that gates `MSG_RUMBLE`
///     vibration and `MSG_LIGHTBAR` colour independently, so the Light bar
///     setting and the Rumble setting never bleed into each other.
///   * `WifiConnection.capabilityWord` — the per-controller `MSG_CONTROLLER_ADD`
///     capability word, advertising `CAP_LIGHTBAR` iff the bound controller
///     has an addressable RGB light.
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
        let msg = SatelliteClient.LightbarMessage(controllerIndex: 0, r: 0x11, g: 0x22, b: 0x33)
        XCTAssertTrue(
            ReturnPathRouting.shouldApply(lightbar: msg, flags: flags(rumble: true, lightbar: true))
        )
    }

    func testLightbarMessageSuppressedWhenLightbarOff() {
        let msg = SatelliteClient.LightbarMessage(controllerIndex: 0, r: 0x11, g: 0x22, b: 0x33)
        XCTAssertFalse(
            ReturnPathRouting.shouldApply(lightbar: msg, flags: flags(rumble: true, lightbar: false))
        )
    }

    func testLightbarMessageIndependentOfRumbleToggle() {
        // The light-bar path does not consult the Rumble toggle: rumble off
        // must not disable MSG_LIGHTBAR.
        let msg = SatelliteClient.LightbarMessage(controllerIndex: 0, r: 1, g: 2, b: 3)
        XCTAssertTrue(
            ReturnPathRouting.shouldApply(lightbar: msg, flags: flags(rumble: false, lightbar: true))
        )
        XCTAssertFalse(
            ReturnPathRouting.shouldApply(lightbar: msg, flags: flags(rumble: false, lightbar: false))
        )
    }

    // MARK: - CAP_LIGHTBAR capability word

    func testCapabilityWordWithLightSetsCapLightbar() {
        let word = WifiConnection.capabilityWord(hasLight: true)
        // CAP_LIGHTBAR bit present.
        XCTAssertEqual(word & WifiConnection.capLightbar, WifiConnection.capLightbar)
        // Exact value: fixed 0x0007 | CAP_LIGHTBAR 0x0008 = 0x000F.
        XCTAssertEqual(word, 0x000F)
    }

    func testCapabilityWordWithoutLightOmitsCapLightbar() {
        let word = WifiConnection.capabilityWord(hasLight: false)
        // CAP_LIGHTBAR bit absent.
        XCTAssertEqual(word & WifiConnection.capLightbar, 0)
        // Exactly the fixed default — no extra bits.
        XCTAssertEqual(word, WifiConnection.defaultCaps)
        XCTAssertEqual(word, 0x0007)
    }

    func testCapabilityWordPreservesFixedBits() {
        // CAP_LIGHTBAR must be OR'd in *without* disturbing the existing
        // analog-triggers / rumble / motion bits.
        let analogTriggers: UInt16 = 0x0001
        let rumble: UInt16 = 0x0002
        let motion: UInt16 = 0x0004
        for hasLight in [true, false] {
            let word = WifiConnection.capabilityWord(hasLight: hasLight)
            XCTAssertEqual(word & analogTriggers, analogTriggers, "CAP_ANALOG_TRIGGERS lost")
            XCTAssertEqual(word & rumble, rumble, "CAP_RUMBLE lost")
            XCTAssertEqual(word & motion, motion, "CAP_MOTION lost")
        }
    }

    func testCapLightbarConstantPinnedToWireValue() {
        // Pinned to the protocol value shared by every dish client +
        // satellite/src/core/types.h. Must not drift.
        XCTAssertEqual(WifiConnection.capLightbar, 0x0008)
    }

    func testCapabilityWordIsAdvertisedIffControllerHasLight() {
        // The "iff" the spec calls for, stated directly: the CAP_LIGHTBAR bit
        // is set exactly when (and only when) the controller has a light.
        XCTAssertTrue((WifiConnection.capabilityWord(hasLight: true) & 0x0008) != 0)
        XCTAssertFalse((WifiConnection.capabilityWord(hasLight: false) & 0x0008) != 0)
    }
}
