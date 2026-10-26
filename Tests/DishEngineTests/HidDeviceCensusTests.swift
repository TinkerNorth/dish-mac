// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Foundation
import GameController
import XCTest
@testable import DishEngine

/// The HID census: what it asks IOKit for, which devices it keeps from their
/// properties, how a pad finds its ids by name, and that Diagnostics watches
/// it only while the page shows.
@MainActor
final class HidDeviceCensusTests: XCTestCase {

    private func properties(
        product: String = "N64 Controller",
        vendor: Int = 0x057E,
        productId: Int = 0x2019,
        transport: String? = "Bluetooth",
        primary: (page: Int, usage: Int)? = (0x01, 0x05),
        pairs: [(page: Int, usage: Int)] = [],
        synthetic: Bool? = nil
    ) -> [String: Any] {
        var properties: [String: Any] = [kIOHIDProductKey: product, kIOHIDVendorIDKey: vendor, kIOHIDProductIDKey: productId]
        properties[kIOHIDTransportKey] = transport
        properties[kIOHIDPrimaryUsagePageKey] = primary?.page
        properties[kIOHIDPrimaryUsageKey] = primary?.usage
        properties[kIOHIDDeviceUsagePairsKey] = pairs.map { [kIOHIDDeviceUsagePageKey: $0.page, kIOHIDDeviceUsageKey: $0.usage] }
        properties[kIOHIDGCSyntheticDeviceKey] = synthetic
        return properties
    }

    // MARK: - The matching

    func testTheMatchingAsksForEachGameUsageOnGenericDesktopAndNoSyntheticDevice() {
        let matching = hidCensusMatching()
        XCTAssertEqual(matching.count, 3)
        XCTAssertEqual(
            matching.compactMap { $0[kIOHIDDeviceUsageKey] as? Int },
            [0x04, 0x05, 0x08],
            "Joystick, GamePad, MultiAxisController"
        )
        for dictionary in matching {
            XCTAssertEqual(dictionary[kIOHIDDeviceUsagePageKey] as? Int, 0x01)
            XCTAssertEqual(dictionary["GCSyntheticDevice"] as? Bool, false, "Apple's only supported way to leave synthetic pads out")
        }
        XCTAssertEqual(kIOHIDGCSyntheticDeviceKey, "GCSyntheticDevice")
    }

    // MARK: - The filter

    func testASyntheticDeviceIsLeftOutAndOneWithoutTheKeyIsKept() {
        XCTAssertNil(hidDeviceFacts(id: 1, properties: properties(synthetic: true), claimed: true))
        XCTAssertNotNil(hidDeviceFacts(id: 1, properties: properties(synthetic: false), claimed: true))
        XCTAssertNotNil(hidDeviceFacts(id: 1, properties: properties(synthetic: nil), claimed: true))
    }

    func testOnlyAGameUsageOnGenericDesktopIsKept() {
        let joystick = properties(primary: (0x01, 0x04))
        let multiAxis = properties(primary: nil, pairs: [(0x01, 0x08)])
        let gamepadAmongPairs = properties(primary: (0x01, 0x06), pairs: [(0x01, 0x06), (0x01, 0x05)])
        let keyboard = properties(primary: (0x01, 0x06), pairs: [(0x01, 0x06)])
        let vendorPage = properties(primary: (0xFF00, 0x05))
        let noUsage = properties(primary: nil)
        XCTAssertNotNil(hidDeviceFacts(id: 1, properties: joystick, claimed: false))
        XCTAssertNotNil(hidDeviceFacts(id: 1, properties: multiAxis, claimed: false))
        XCTAssertNotNil(hidDeviceFacts(id: 1, properties: gamepadAmongPairs, claimed: false))
        XCTAssertNil(hidDeviceFacts(id: 1, properties: keyboard, claimed: false))
        XCTAssertNil(hidDeviceFacts(id: 1, properties: vendorPage, claimed: false), "usage 5 on a vendor page is not a gamepad")
        XCTAssertNil(hidDeviceFacts(id: 1, properties: noUsage, claimed: false))
    }

    func testAKeptDeviceCarriesItsNameItsIdsItsTransportAndTheClaim() {
        let unclaimed = hidDeviceFacts(id: 7, properties: properties(), claimed: false)
        XCTAssertEqual(unclaimed, HidDeviceFacts(
            id: 7,
            name: "N64 Controller",
            hardwareId: HidHardwareId(vendorId: 0x057E, productId: 0x2019),
            transport: .bluetooth,
            claimedByGameController: false
        ))
        XCTAssertEqual(hidDeviceFacts(id: 7, properties: properties(), claimed: true)?.claimedByGameController, true)
        let bare: [String: Any] = [kIOHIDPrimaryUsagePageKey: 0x01, kIOHIDPrimaryUsageKey: 0x05]
        let nameless = hidDeviceFacts(id: 8, properties: bare, claimed: false)
        XCTAssertEqual(nameless?.name, "")
        XCTAssertEqual(nameless?.hardwareId, HidHardwareId(vendorId: 0, productId: 0))
        XCTAssertEqual(nameless?.transport, .unknown)
    }

    func testTheTransportWordBecomesItsCase() {
        XCTAssertEqual(hidTransport("USB"), .usb)
        XCTAssertEqual(hidTransport("Bluetooth"), .bluetooth)
        XCTAssertEqual(hidTransport("BluetoothLowEnergy"), .bluetooth)
        XCTAssertEqual(hidTransport("SPI"), .other("SPI"))
        XCTAssertEqual(hidTransport(""), .unknown)
        XCTAssertEqual(hidTransport(nil), .unknown)
    }

    // MARK: - A pad's ids

    private func device(_ id: UInt64, _ name: String, pid: Int, claimed: Bool = true) -> HidDeviceFacts {
        HidDeviceFacts(
            id: id,
            name: name,
            hardwareId: HidHardwareId(vendorId: 0x054C, productId: pid),
            transport: .usb,
            claimedByGameController: claimed
        )
    }

    func testAPadFindsItsIdsOnlyWhenOneClaimedDeviceCarriesItsName() {
        let dualSense = device(1, "DualSense Wireless Controller", pid: 0x0CE6)
        XCTAssertEqual(hardwareId(forPadNamed: "dualsense wireless controller ", in: [dualSense]), dualSense.hardwareId)
        XCTAssertNil(hardwareId(forPadNamed: "Xbox Wireless Controller", in: [dualSense]), "no device carries the name")
        let unclaimed = device(2, "DualSense Wireless Controller", pid: 0x0CE6, claimed: false)
        XCTAssertNil(
            hardwareId(forPadNamed: "DualSense Wireless Controller", in: [unclaimed]),
            "a device GameController does not claim is no pad"
        )
        let twin = device(3, "DualSense Wireless Controller", pid: 0x0CE6)
        XCTAssertEqual(
            hardwareId(forPadNamed: "DualSense Wireless Controller", in: [dualSense, twin]),
            dualSense.hardwareId,
            "twins share ids"
        )
        let edge = device(4, "DualSense Wireless Controller", pid: 0x0DF2)
        XCTAssertNil(hardwareId(forPadNamed: "DualSense Wireless Controller", in: [dualSense, edge]), "two ids under one name say nothing")
    }

    // MARK: - Diagnostics

    func testDiagnosticsWatchesTheCensusOnlyWhileShownAndReReadsOnAChange() throws {
        let census = FakeHidCensus()
        let suite = "dish.test.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ConnectionStore(defaults: defaults, keyStore: InMemoryKeyStore())
        let wifi = WifiConnectionManager(store: store)
        let source = DiagnosticsSource(wifi: wifi, hub: ConnectionHub(wifi: wifi, store: store), census: census)
        let pad = ControllerSlot(id: "pad", name: "DualSense Wireless Controller")
        source.useSlots { [pad] }
        census.present = [device(1, "DualSense Wireless Controller", pid: 0x0CE6), device(2, "Arcade Stick", pid: 0x0001, claimed: false)]
        XCTAssertFalse(census.watching)
        source.start()
        XCTAssertTrue(census.watching)
        XCTAssertEqual(source.state.inputDevices.map(\.id), [1, 2])
        XCTAssertEqual(source.state.pads.first?.hardwareId, HidHardwareId(vendorId: 0x054C, productId: 0x0CE6))
        census.present = []
        census.announceChange()
        XCTAssertEqual(source.state.inputDevices, [], "a removal re-reads at once")
        XCTAssertNil(source.state.pads.first?.hardwareId)
        source.stop()
        XCTAssertFalse(census.watching)
    }
}

/// A census over a device list the test sets, recording whether it is watched.
@MainActor
final class FakeHidCensus: HidCensusReading {
    var present: [HidDeviceFacts] = []
    private(set) var watching = false
    private var changed: () -> Void = {}

    func start(changed: @escaping () -> Void) {
        watching = true
        self.changed = changed
    }

    func stop() {
        watching = false
    }

    func devices() -> [HidDeviceFacts] {
        watching ? present : []
    }

    func announceChange() {
        changed()
    }
}
