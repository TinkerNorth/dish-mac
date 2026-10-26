// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import XCTest
@testable import DishEngine

/// Coverage for the light-bar return path:
///
///   * `ReturnPathRouting` — the pure decision layer that gates `MSG_RUMBLE`
///     vibration and `MSG_LIGHTBAR` colour independently, so the Light bar
///     setting and the Rumble setting never bleed into each other.
///   * `WifiConnection.desiredDescriptors` — the declarative-PUT seam; the
///     caps word itself is `descriptorCaps`, pinned in DescriptorCapsTests.
///
/// Exercised as pure functions: no socket, no live `GCController`.
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

    // MARK: - desiredDescriptors (the declarative-PUT seam)

    @MainActor
    func testNoDescriptorWithoutABoundSlot() {
        let conn = WifiConnection(
            id: "wifi:127.0.0.1:9876",
            server: DiscoveredServer(name: "S", ip: "127.0.0.1", udpPort: 9876, pairPort: 9443, httpPort: 9443)
        )
        XCTAssertEqual(conn.desiredDescriptors, [], "zero-controller session: no descriptor")
    }

    @MainActor
    func testTheDescriptorReflectsTheBoundSlotsCapabilities() {
        let conn = WifiConnection(
            id: "wifi:127.0.0.1:9876",
            server: DiscoveredServer(name: "S", ip: "127.0.0.1", udpPort: 9876, pairPort: 9443, httpPort: 9443)
        )
        conn.attachSlot(
            "slot-a",
            controllerType: 0,
            capabilities: ControllerCapabilities(hasMotion: true, hasRumble: true, hasLightbar: true)
        )
        let descriptor = conn.descriptor(for: "slot-a")
        XCTAssertEqual(descriptor?.ctrlIdx, 0)
        XCTAssertEqual(descriptor?.type, ProtocolConstants.controllerTypeXbox)
        XCTAssertEqual(descriptor?.caps, 0x000F)
        XCTAssertEqual(descriptor?.touchpadMode, .off)

        conn.detachSlot("slot-a")
        XCTAssertEqual(conn.desiredDescriptors, [], "detach empties the desired set")
    }
}
