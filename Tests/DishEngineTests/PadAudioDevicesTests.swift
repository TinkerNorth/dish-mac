// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import XCTest
@testable import DishEngine

/// Which Core Audio devices are a pad's own audio function, and what each
/// carries: the DualSense's mic, speaker and haptics lanes; the DualShock
/// 4 v2's headset; nothing over Bluetooth or from a soundcard.
final class PadAudioDevicesTests: XCTestCase {

    private func device(_ name: String, usb: Bool = true, inputs: Int = 1, outputs: Int = 4, id: UInt32 = 1) -> AudioDeviceFacts {
        AudioDeviceFacts(id: id, uid: "uid-\(id)", name: name, isUSB: usb, inputChannels: inputs, outputChannels: outputs)
    }

    func testADualSenseOnUSBCarriesEverything() throws {
        let functions = padAudioFunctions(in: [device("DualSense Wireless Controller")])
        let pad = try XCTUnwrap(functions.first)
        XCTAssertEqual(pad.family, .dualSense)
        XCTAssertTrue(pad.hasMic)
        XCTAssertTrue(pad.hasSpeaker)
        XCTAssertTrue(pad.hasHapticLanes)
    }

    func testADualShockHeadsetHasNoHapticsLanes() throws {
        let pad = try XCTUnwrap(padAudioFunctions(in: [device("Wireless Controller", outputs: 2)]).first)
        XCTAssertEqual(pad.family, .dualShock4)
        XCTAssertTrue(pad.hasMic)
        XCTAssertTrue(pad.hasSpeaker)
        XCTAssertFalse(pad.hasHapticLanes)
    }

    func testOnlyUSBPadsQualify() {
        XCTAssertEqual(
            padAudioFunctions(in: [device("DualSense Wireless Controller", usb: false)]),
            [],
            "Bluetooth exposes no audio function"
        )
        XCTAssertEqual(
            padAudioFunctions(in: [device("MacBook Pro Speakers", outputs: 2), device("Scarlett 2i2 USB", inputs: 2, outputs: 2)]),
            []
        )
    }

    func testTheHALsOrderIsKeptForMatchingPadsToDevices() {
        let functions = padAudioFunctions(in: [
            device("Built-in Output", usb: false, id: 1),
            device("DualSense Wireless Controller", id: 2),
            device("DualSense Wireless Controller", id: 3)
        ])
        XCTAssertEqual(functions.map(\.device.id), [2, 3])
    }

    func testAFourChannelOutWithoutTheDualSenseNameHasNoHaptics() throws {
        let pad = try XCTUnwrap(padAudioFunctions(in: [device("Wireless Controller", outputs: 4)]).first)
        XCTAssertFalse(pad.hasHapticLanes, "only the DualSense's lanes 3 and 4 are haptics")
    }

    func testTheCatalogReadsTheHALWithoutFailing() {
        let devices = CoreAudioDeviceCatalog.devices()
        for facts in devices {
            XCTAssertFalse(facts.uid.isEmpty, "every device has a UID")
        }
    }
}
