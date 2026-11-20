// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import XCTest

final class BundlePadPathsTests: XCTestCase {

    func testARefusedEndpointOutranksThePlan() {
        XCTAssertEqual(bundleVoice(open: true, refused: true, routed: true, frames: 3).voice, .refused)
    }

    func testAPlannedVoiceIsOpen() {
        XCTAssertEqual(
            bundleVoice(open: true, refused: false, routed: true, frames: 3),
            BundleVoice(voice: .open, device: "pad", frames: 3)
        )
    }

    func testAnUnplannedVoiceIsClosed() {
        XCTAssertEqual(bundleVoice(open: false, refused: false, routed: true, frames: 0).voice, .closed)
    }

    func testAPadWithoutItsOwnEndpointHasNoDevice() {
        XCTAssertNil(bundleVoice(open: false, refused: false, routed: false, frames: 0).device)
    }

    func testABluetoothPadIsReadThroughHidOverTheLinkIOKitNamed() {
        XCTAssertEqual(bundleBluetooth(.bluetooth, layer: .classic), BundleBluetooth(profile: "hid", transportLayer: "classic"))
        XCTAssertEqual(bundleBluetooth(.bluetooth, layer: .le), BundleBluetooth(profile: "hid", transportLayer: "le"))
    }

    func testABluetoothPadWhoseLinkIOKitDidNotNameSaysNull() {
        XCTAssertEqual(bundleBluetooth(.bluetooth, layer: nil), BundleBluetooth(profile: "hid", transportLayer: nil))
    }

    func testAPadOffBluetoothHasNoBluetoothFacts() {
        XCTAssertNil(bundleBluetooth(.usb, layer: nil))
        XCTAssertNil(bundleBluetooth(.usb, layer: .le), "a layer on a USB pad is not a Bluetooth link")
        XCTAssertNil(bundleBluetooth(nil, layer: nil))
    }
}
