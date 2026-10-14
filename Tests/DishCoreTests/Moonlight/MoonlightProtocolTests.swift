// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import XCTest
@testable import DishCore

/// The facts the three sibling clients and Wolf's source agree on, pinned
/// once so a typo in a constant fails here before it fails on a host.
final class MoonlightProtocolTests: XCTestCase {

    func testPortsServiceAndPadLimit() {
        XCTAssertEqual(MoonlightProtocol.httpPort, 47989)
        XCTAssertEqual(MoonlightProtocol.httpsPort, 47984)
        XCTAssertEqual(MoonlightProtocol.defaultRtspPort, 48010)
        XCTAssertEqual(MoonlightProtocol.bonjourType, "_nvstream._tcp")
        XCTAssertEqual(MoonlightProtocol.maxPads, 4)
    }

    func testTheButtonWordsAndTheReservedBit() {
        XCTAssertEqual(MoonlightButton.buttonA | MoonlightButton.buttonB | MoonlightButton.buttonX | MoonlightButton.buttonY, 0xF000)
        XCTAssertEqual(MoonlightButton.reservedMicMute, 0x0800, "XUSB's unassigned bit, the satellite's mic mute, no Moonlight button")
        XCTAssertEqual(MoonlightButton.touchpad, 0x100000)
        XCTAssertEqual(MoonlightButton.home, 0x0400)
    }

    func testTheCapabilityByteAndTheTypes() {
        XCTAssertEqual(
            MoonlightCapability.analogTriggers | MoonlightCapability.rumble | MoonlightCapability.triggerRumble | MoonlightCapability
                .battery, 0x47
        )
        XCTAssertEqual(
            MoonlightCapability.touchpad | MoonlightCapability.accelerometer | MoonlightCapability.gyro | MoonlightCapability.rgbLed,
            0xB8
        )
        XCTAssertEqual(MoonlightControllerType.auto, 0xFF, "client-side only")
        XCTAssertEqual([MoonlightControllerType.xbox, MoonlightControllerType.playStation, MoonlightControllerType.nintendo], [1, 2, 3])
    }

    func testTheBatteryStatesAndTheUnknownPercentage() {
        XCTAssertEqual(MoonlightBatteryState.notPresent, 1)
        XCTAssertEqual(MoonlightBatteryState.charging, 3)
        XCTAssertEqual(MoonlightBatteryState.full, 5)
        XCTAssertEqual(MoonlightBatteryState.percentageUnknown, 0xFF)
    }
}
