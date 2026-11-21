// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import IOKit
import XCTest
@testable import DishEngine

/// A pad's raw USB descriptors (its device descriptor, then each
/// configuration descriptor in index order), read through IOKit without
/// opening the pad and fingerprinted by SHA-256, once per USB device, as
/// Diagnostics composes.
@MainActor
final class DescriptorFingerprintTests: XCTestCase {

    private let raw = UsbRawDescriptors(device: [0x12, 0x01, 0x00, 0x02], configurations: [[0x09, 0x02, 0x29, 0x00]])
    private var reader: FakeUsbDescriptorReader!
    private var census: FakeHidCensus!
    private var source: DiagnosticsSource!
    private var suite: String!

    override func setUp() {
        super.setUp()
        reader = FakeUsbDescriptorReader()
        census = FakeHidCensus()
        suite = "dish.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        let store = ConnectionStore(defaults: defaults, keyStore: InMemoryKeyStore())
        let wifi = WifiConnectionManager(store: store)
        source = DiagnosticsSource(wifi: wifi, hub: ConnectionHub(wifi: wifi, store: store), census: census, descriptors: reader)
    }

    override func tearDown() {
        source.stop()
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func gameControllerPad(usbDeviceId: UInt64?, transport: HidTransport = .usb) -> HidDeviceFacts {
        var device = HidDeviceFacts(
            id: 1,
            name: "DualSense Wireless Controller",
            hardwareId: HidHardwareId(vendorId: 0x054C, productId: 0x0CE6),
            transport: transport,
            claimedByGameController: true
        )
        device.usbDeviceId = usbDeviceId
        return device
    }

    func testAUsbPadsFingerprintIsTheSha256OfItsRawDescriptorsReadOncePerDevice() throws {
        reader.descriptors = [42: raw]
        census.present = [gameControllerPad(usbDeviceId: 42)]
        source.useSlots { [ControllerSlot(id: "pad", name: "DualSense Wireless Controller")] }
        source.start()
        source.refresh()
        let pad = try XCTUnwrap(source.state.pads.first)
        XCTAssertEqual(pad.hardwareDetail?.descriptorSha256, sha256Hex(Data([0x12, 0x01, 0x00, 0x02, 0x09, 0x02, 0x29, 0x00])))
        XCTAssertEqual(pad.usbDescriptors, raw, "the capture's configuration comes from them")
        XCTAssertEqual(reader.asked, [42], "the descriptors do not change while the device stays")
    }

    func testAPadOffUsbHasNoFingerprintAndNothingIsRead() throws {
        census.present = [gameControllerPad(usbDeviceId: nil, transport: .bluetooth(.classic))]
        source.useSlots { [ControllerSlot(id: "pad", name: "DualSense Wireless Controller")] }
        source.start()
        XCTAssertNil(try XCTUnwrap(source.state.pads.first).hardwareDetail?.descriptorSha256)
        XCTAssertEqual(reader.asked, [])
    }

    func testWhenIOKitHandsNoDescriptorsTheFingerprintIsNull() throws {
        census.present = [gameControllerPad(usbDeviceId: 42)]
        source.useSlots { [ControllerSlot(id: "pad", name: "DualSense Wireless Controller")] }
        source.start()
        source.refresh()
        XCTAssertNil(try XCTUnwrap(source.state.pads.first).hardwareDetail?.descriptorSha256)
        XCTAssertEqual(reader.asked, [42], "an answer of none is kept too")
    }

    func testAHidPadsEndpointsComeFromItsConfigurationDescriptor() throws {
        let configuration: [UInt8] = [
            0x09, 0x02, 0x20, 0x00, 0x01, 0x01, 0x00, 0x80, 0x32,
            0x09, 0x04, 0x02, 0x00, 0x02, 0x03, 0x00, 0x00, 0x00,
            0x07, 0x05, 0x81, 0x03, 0x40, 0x00, 0x04,
            0x07, 0x05, 0x02, 0x03, 0x40, 0x00, 0x04
        ]
        reader.descriptors = [42: UsbRawDescriptors(device: [0x12, 0x01], configurations: [configuration], currentConfiguration: 1)]
        var device = gameControllerPad(usbDeviceId: 42)
        device.detail.interfaceNumber = 2
        census.present = [device]
        source.useSlots { [ControllerSlot(id: "pad", name: "DualSense Wireless Controller")] }
        source.start()
        XCTAssertEqual(try XCTUnwrap(source.state.pads.first).hardwareDetail?.endpoints, BundleEndpoints(input: 0x81, output: 0x02))
    }

    func testTwinsOfOneModelShareTheirDescriptorsAndSoTheFingerprint() throws {
        reader.descriptors = [42: raw, 43: raw]
        var twin = gameControllerPad(usbDeviceId: 43)
        twin = HidDeviceFacts(id: 2, name: twin.name, hardwareId: twin.hardwareId, transport: .usb, claimedByGameController: true)
        twin.usbDeviceId = 43
        census.present = [gameControllerPad(usbDeviceId: 42), twin]
        source.useSlots { [ControllerSlot(id: "pad", name: "DualSense Wireless Controller")] }
        source.start()
        XCTAssertEqual(try XCTUnwrap(source.state.pads.first).usbDescriptors, raw)
    }

    func testADirectPadIsFingerprintedByTheUsbDeviceOfTheInterfaceItReads() throws {
        reader.descriptors = [7: raw]
        var path = SlotInputPath(source: .direct, reason: .macOSCannotRead)
        path.hardwareId = HidHardwareId(vendorId: 0x2DC8, productId: 0x310B)
        path.hardware = HidHardwareDetail(versionNumber: 0x0114)
        path.usbDeviceId = 7
        source.useSlots { [ControllerSlot(id: "hid:2dc8:310b", name: "8BitDo Ultimate 2 Wireless Controller")] }
        let paths: (String) -> SlotInputPath? = { _ in path }
        source.useInputPaths(paths, tick: {})
        source.start()
        let pad = try XCTUnwrap(source.state.pads.first)
        XCTAssertEqual(pad.hardwareDetail?.descriptorSha256, sha256Hex(Data(raw.bytes)))
        XCTAssertEqual(pad.hardwareDetail?.versionNumber, 0x0114)
    }
}

extension DescriptorFingerprintTests {

    // MARK: - IOKit, on this machine

    func testIOKitHandsNothingForAnIdNoEntryHas() {
        XCTAssertNil(IOKitUsbDescriptorReader().rawDescriptors(ofUsbDevice: 0xFFFF_FFFF_FFFF))
    }

    func testIOKitHandsNothingForAServiceThatIsNoUsbDevice() throws {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDDevice"))
        try XCTSkipIf(service == 0, "this machine lists no HID device")
        defer { IOObjectRelease(service) }
        var registryId: UInt64 = 0
        XCTAssertEqual(IORegistryEntryGetRegistryEntryID(service, &registryId), KERN_SUCCESS)
        XCTAssertNil(IOKitUsbDescriptorReader().rawDescriptors(ofUsbDevice: registryId))
    }
}

/// Raw descriptors by USB device, and every id the source asked for.
@MainActor
final class FakeUsbDescriptorReader: UsbDescriptorReading {
    var descriptors: [UInt64: UsbRawDescriptors] = [:]
    private(set) var asked: [UInt64] = []

    func rawDescriptors(ofUsbDevice registryId: UInt64) -> UsbRawDescriptors? {
        asked.append(registryId)
        return descriptors[registryId]
    }
}
