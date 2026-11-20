// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import IOKit.hid
import XCTest
@testable import DishEngine

/// What IOKit says of a pad's hardware beyond its ids, read from its
/// properties and its USB device's IORegistry entries: the version, the
/// report descriptor's fingerprint and the interfaces.
final class HidHardwareDetailTests: XCTestCase {

    func testTheVersionNumberIsWhatIOKitNamesIt() {
        XCTAssertEqual(kIOHIDVersionNumberKey, "VersionNumber")
        XCTAssertEqual(hidHardwareDetail([kIOHIDVersionNumberKey: 0x0107]).versionNumber, 0x0107)
    }

    func testTheReportDescriptorIsFingerprintedBySha256OfItsBytes() {
        let descriptor = Data(DirectFixtures.gamepadDescriptor)
        let detail = hidHardwareDetail([kIOHIDReportDescriptorKey: descriptor])
        XCTAssertEqual(detail.descriptorSha256, sha256Hex(descriptor))
        XCTAssertEqual(detail.descriptorSha256?.count, 64)
    }

    func testAnEmptyDescriptorHasNoFingerprint() {
        XCTAssertNil(hidHardwareDetail([kIOHIDReportDescriptorKey: Data()]).descriptorSha256)
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
