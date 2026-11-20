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

    func testABluetoothPadIsReadThroughHidAndItsLayerIsNotKnown() {
        XCTAssertEqual(bundleBluetooth(.bluetooth), BundleBluetooth(profile: "hid", transportLayer: nil))
    }

    func testAPadOffBluetoothHasNoBluetoothFacts() {
        XCTAssertNil(bundleBluetooth(.usb))
        XCTAssertNil(bundleBluetooth(nil))
    }
}
