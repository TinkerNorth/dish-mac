// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishEngine
import XCTest
@testable import Dish

/// The game devices GameController leaves out, as Android's "Other input
/// devices" cards, and a pad's USB ID once the census finds it.
final class InputDevicesMappersTests: XCTestCase {

    private func device(_ id: UInt64, _ name: String, claimed: Bool, transport: HidTransport = .bluetooth) -> HidDeviceFacts {
        HidDeviceFacts(
            id: id,
            name: name,
            hardwareId: HidHardwareId(vendorId: 0x057E, productId: 0x2019),
            transport: transport,
            claimedByGameController: claimed
        )
    }

    func testADeviceGameControllerLeavesOutGetsACardWithItsStatusItsIdAndItsConnection() {
        let card = inputDeviceCard(device(7, "N64 Controller", claimed: false))
        XCTAssertEqual(card.id, "hid:7")
        XCTAssertEqual(card.title, "N64 Controller")
        XCTAssertNil(card.inspects, "there is no input to inspect")
        XCTAssertEqual(card.supportKey, "057e:2019", "its help-support capture opens it by its USB identity")
        XCTAssertEqual(card.lines, [
            FactLine(key: "Status", value: "Not a controller: not claimed by GameController"),
            FactLine(key: "Hardware ID", value: "057e:2019"),
            FactLine(key: "Connection", value: "Bluetooth")
        ])
    }

    func testANamelessDeviceIsTitledUnknown() {
        XCTAssertEqual(inputDeviceCard(device(1, "", claimed: false)).title, L10n.app.unknown)
    }

    func testTheSectionShowsOnlyWhileADeviceIsLeftOut() throws {
        XCTAssertNil(otherInputDevicesState([]))
        XCTAssertNil(otherInputDevicesState([device(1, "DualSense Wireless Controller", claimed: true)]), "a claimed pad is a controller")
        let state = try XCTUnwrap(otherInputDevicesState([device(1, "Pad", claimed: true), device(2, "Stick", claimed: false)]))
        XCTAssertEqual(state.title, "Other input devices")
        XCTAssertEqual(state.note, "Dish does not treat these as controllers.")
        XCTAssertEqual(state.cards.map(\.title), ["Stick"])
    }

    func testThePageCarriesTheSectionFromTheSnapshot() {
        var facts = ShellFacts()
        XCTAssertNil(diagnosticsPageState(facts: facts).otherDevices)
        facts.diagnostics = DiagnosticsSnapshot(inputDevices: [device(2, "Stick", claimed: false)])
        XCTAssertEqual(diagnosticsPageState(facts: facts).otherDevices?.cards.map(\.id), ["hid:2"])
    }

    func testEveryTransportIsWorded() {
        XCTAssertEqual(transportText(.usb), "USB")
        XCTAssertEqual(transportText(.bluetooth), "Bluetooth")
        XCTAssertEqual(transportText(.other("SPI")), "SPI", "IOKit's own word")
        XCTAssertEqual(transportText(.unknown), L10n.app.unknown)
    }

    func testAHardwareIdIsFourLowercaseHexDigitsAPart() {
        XCTAssertEqual(hardwareIdText(HidHardwareId(vendorId: 0x54C, productId: 0xCE6)), "054c:0ce6")
        XCTAssertEqual(hardwareIdText(HidHardwareId(vendorId: 0, productId: 0xFFFF)), "0000:ffff")
    }

    func testAPadTheCensusFindsShowsItsUsbIdUnderItsConnection() {
        let slot = ControllerSlot(id: "pad", name: "DualSense")
        let found = padLines(PadDiagnostics(slot: slot, wire: nil, hardwareId: HidHardwareId(vendorId: 0x054C, productId: 0x0CE6)))
        XCTAssertEqual(Array(found.prefix(2)), [
            FactLine(key: "Connection", value: "GameController"),
            FactLine(key: "USB ID", value: "054c:0ce6")
        ])
        let unfound = padLines(PadDiagnostics(slot: slot, wire: nil))
        XCTAssertFalse(unfound.contains { $0.key == "USB ID" }, "no line until the census finds the pad")
    }
}
