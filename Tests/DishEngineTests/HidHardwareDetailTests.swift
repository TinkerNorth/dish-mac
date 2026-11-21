// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import IOKit.hid
import XCTest
@testable import DishEngine

/// What IOKit says of a pad's hardware beyond its ids, read from its
/// properties and its USB device's IORegistry entries: the version, the
/// interfaces, and the raw USB descriptors the fingerprint is taken of.
final class HidHardwareDetailTests: XCTestCase {

    func testTheVersionNumberIsWhatIOKitNamesIt() {
        XCTAssertEqual(kIOHIDVersionNumberKey, "VersionNumber")
        XCTAssertEqual(hidHardwareDetail([kIOHIDVersionNumberKey: 0x0107]).versionNumber, 0x0107)
    }

    func testTheHidReportDescriptorIsNotTheDescriptorFingerprint() {
        let detail = hidHardwareDetail([kIOHIDReportDescriptorKey: Data(DirectFixtures.gamepadDescriptor)])
        XCTAssertNil(detail.descriptorSha256, "the fingerprint is of the raw USB descriptors; the report descriptor is the capture's")
    }

    // MARK: - The raw USB descriptors

    /// A DualSense's device descriptor fields as the IORegistry lists them.
    private let dualSenseFields: [String: Any] = [
        "bcdUSB": 0x0200, "bDeviceClass": 0, "bDeviceSubClass": 0, "bDeviceProtocol": 0, "bMaxPacketSize0": 64,
        "idVendor": 0x054C, "idProduct": 0x0CE6, "bcdDevice": 0x0100, "iManufacturer": 1, "iProduct": 2,
        "iSerialNumber": 0, "bNumConfigurations": 1
    ]

    func testTheDeviceDescriptorIsRebuiltFromTheRegistrysFieldsInTheBusesOrder() {
        let expected: [UInt8] = [0x12, 0x01, 0x00, 0x02, 0x00, 0x00, 0x00, 0x40, 0x4C, 0x05, 0xE6, 0x0C, 0x00, 0x01, 0x01, 0x02, 0x00, 0x01]
        XCTAssertEqual(usbDeviceDescriptor(dualSenseFields), expected, "eighteen bytes, the words little-endian")
    }

    func testADeviceMissingAFieldHasNoDeviceDescriptor() {
        var partial = dualSenseFields
        partial.removeValue(forKey: "bMaxPacketSize0")
        XCTAssertNil(usbDeviceDescriptor(partial))
    }

    func testTheRawDescriptorsAreTheDeviceDescriptorThenEachConfigurationInIndexOrder() {
        let raw = UsbRawDescriptors(device: [0x12, 0x01], configurations: [[0x09, 0x02, 0x01], [0x09, 0x02, 0x02]])
        XCTAssertEqual(raw.bytes, [0x12, 0x01, 0x09, 0x02, 0x01, 0x09, 0x02, 0x02])
    }

    // MARK: - A HID pad's endpoints, from its configuration descriptor

    /// A DualSense-shaped configuration as the bus delivers it: an audio
    /// control interface, an audio streaming one whose alternate setting 0
    /// has an isochronous IN, its setting 1 another, and the HID interface 3
    /// with its interrupt IN 0x84 and OUT 0x03.
    private let dualSenseConfiguration: [UInt8] = [
        0x09, 0x02, 0x52, 0x00, 0x03, 0x01, 0x00, 0xC0, 0xFA,
        0x09, 0x04, 0x00, 0x00, 0x00, 0x01, 0x01, 0x00, 0x00,
        0x09, 0x04, 0x01, 0x00, 0x01, 0x01, 0x02, 0x00, 0x00,
        0x07, 0x05, 0x82, 0x05, 0x88, 0x01, 0x04,
        0x09, 0x04, 0x02, 0x01, 0x01, 0x01, 0x02, 0x00, 0x00,
        0x07, 0x05, 0x86, 0x03, 0x40, 0x00, 0x04,
        0x09, 0x04, 0x03, 0x00, 0x02, 0x03, 0x00, 0x00, 0x00,
        0x09, 0x21, 0x11, 0x01, 0x00, 0x01, 0x22, 0x11, 0x01,
        0x07, 0x05, 0x84, 0x03, 0x40, 0x00, 0x06,
        0x07, 0x05, 0x03, 0x03, 0x40, 0x00, 0x06
    ]

    func testAHidInterfacesEndpointsAreItsInterruptInAndOut() {
        let raw = UsbRawDescriptors(device: [], configurations: [dualSenseConfiguration], currentConfiguration: 1)
        XCTAssertEqual(interruptEndpoints(raw, interfaceNumber: 3), BundleEndpoints(input: 0x84, output: 0x03))
    }

    func testAnInterfaceWithNoInterruptInHasNoEndpoints() {
        let raw = UsbRawDescriptors(device: [], configurations: [dualSenseConfiguration], currentConfiguration: 1)
        XCTAssertNil(interruptEndpoints(raw, interfaceNumber: 1), "an isochronous endpoint is audio, not the pad's")
        XCTAssertNil(interruptEndpoints(raw, interfaceNumber: 7), "no such interface")
    }

    func testOnlyAlternateSettingZeroIsRead() {
        let raw = UsbRawDescriptors(device: [], configurations: [dualSenseConfiguration], currentConfiguration: 1)
        XCTAssertNil(interruptEndpoints(raw, interfaceNumber: 2), "interface 2 is listed at setting 1 alone")
    }

    func testAnInterfaceWithOnlyAnInEndpointHasNoOut() {
        let inOnly = Array(dualSenseConfiguration.dropLast(7))
        let raw = UsbRawDescriptors(device: [], configurations: [inOnly], currentConfiguration: 1)
        XCTAssertEqual(interruptEndpoints(raw, interfaceNumber: 3), BundleEndpoints(input: 0x84, output: nil))
    }

    func testTheConfigurationInForceIsTheOneRead() {
        var second = dualSenseConfiguration
        second[5] = 2
        second[second.count - 12] = 0x85
        let raw = UsbRawDescriptors(device: [], configurations: [dualSenseConfiguration, second], currentConfiguration: 2)
        XCTAssertEqual(interruptEndpoints(raw, interfaceNumber: 3)?.input, 0x85)
    }

    func testADescriptorOfLengthZeroEndsTheWalk() {
        let raw = UsbRawDescriptors(device: [], configurations: [[0x09, 0x02, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x04]])
        XCTAssertNil(interruptEndpoints(raw, interfaceNumber: 0))
    }

    func testTheHidInterfacesNumberRidesTheDetail() {
        XCTAssertEqual(hidHardwareDetail([hidInterfaceNumberKey: 3]).interfaceNumber, 3)
    }

    func testTheUserClientIsIOUSBLibsAsTheSdkNamesIt() {
        XCTAssertEqual(CFUUIDCreateString(nil, usbDeviceUserClientType) as String, "9DC7B780-9EC0-11D4-A54F-000A27052861")
        XCTAssertEqual(CFUUIDCreateString(nil, ioCFPlugInInterfaceType) as String, "C244E858-109C-11D4-91D4-0050E4C6426F")
        XCTAssertEqual(CFUUIDCreateString(nil, usbDeviceInterfaceType) as String, "5C8187D0-9EF3-11D4-8B45-000A27052861")
    }

    func testADeviceThatNamesNeitherHasNeither() {
        let detail = hidHardwareDetail([:])
        XCTAssertNil(detail.versionNumber)
        XCTAssertNil(detail.descriptorSha256)
        XCTAssertNil(detail.interfaces, "the IORegistry is read apart")
        XCTAssertNil(detail.endpoints)
    }

    func testEachInterfaceIsItsNumberAndClassTripleInNumberOrder() {
        let entries: [[String: Any]] = [
            [
                UsbInterfaceKey.interfaceNumber: 3, UsbInterfaceKey.interfaceClass: 0x03,
                UsbInterfaceKey.interfaceSubclass: 0x00, UsbInterfaceKey.interfaceProtocol: 0x00
            ],
            [
                UsbInterfaceKey.interfaceNumber: 0, UsbInterfaceKey.interfaceClass: 0x01,
                UsbInterfaceKey.interfaceSubclass: 0x01, UsbInterfaceKey.interfaceProtocol: 0x00
            ]
        ]
        XCTAssertEqual(usbInterfaces(entries), [
            BundleUsbInterface(number: 0, interfaceClass: 0x01, subclass: 0x01, interfaceProtocol: 0x00),
            BundleUsbInterface(number: 3, interfaceClass: 0x03, subclass: 0x00, interfaceProtocol: 0x00)
        ])
    }

    func testAnInterfaceEntryMissingAKeyIsLeftOut() {
        let partial: [[String: Any]] = [[UsbInterfaceKey.interfaceNumber: 1, UsbInterfaceKey.interfaceClass: 0xFF]]
        XCTAssertEqual(usbInterfaces(partial), [])
    }

    func testTheInterfaceKeysAreTheSdksMatchingKeys() {
        XCTAssertEqual(UsbInterfaceKey.interfaceNumber, "bInterfaceNumber")
        XCTAssertEqual(UsbInterfaceKey.interfaceClass, "bInterfaceClass")
        XCTAssertEqual(UsbInterfaceKey.interfaceSubclass, "bInterfaceSubClass")
        XCTAssertEqual(UsbInterfaceKey.interfaceProtocol, "bInterfaceProtocol")
        XCTAssertEqual(UsbInterfaceKey.deviceRelease, "bcdDevice")
    }

    func testOnlyAUsbDeviceIsLookedForInTheRegistry() {
        XCTAssertTrue(looksForUsbDevice(.usb))
        XCTAssertFalse(looksForUsbDevice(.bluetooth(.le)))
        XCTAssertFalse(looksForUsbDevice(.other("SPI")))
        XCTAssertFalse(looksForUsbDevice(.unknown))
    }
}
