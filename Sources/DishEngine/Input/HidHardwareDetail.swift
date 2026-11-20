// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// What IOKit says of a pad's hardware beyond its ids, for the diagnostics
// file: the version and the report descriptor from the HID device's own
// properties, and the interfaces of the USB device above it from the
// IORegistry, all read without opening anything.

import DishCore
import Foundation
import IOKit.hid

/// What IOKit says of a pad's hardware beyond its ids.
package struct HidHardwareDetail: Equatable {
    /// `kIOHIDVersionNumberKey`: a USB pad's `bcdDevice`.
    package var versionNumber: Int?
    /// SHA-256 of `kIOHIDReportDescriptorKey`, lowercase hex.
    package var descriptorSha256: String?
    /// The USB device's interfaces as the IORegistry lists them; nil off
    /// USB, or when no USB device is above the pad.
    package var interfaces: [BundleUsbInterface]?
    /// The endpoints of an interface Dish opened itself; nil where IOKit
    /// does not say.
    package var endpoints: BundleEndpoints?

    package init(
        versionNumber: Int? = nil,
        descriptorSha256: String? = nil,
        interfaces: [BundleUsbInterface]? = nil,
        endpoints: BundleEndpoints? = nil
    ) {
        self.versionNumber = versionNumber
        self.descriptorSha256 = descriptorSha256
        self.interfaces = interfaces
        self.endpoints = endpoints
    }
}

/// The properties the detail reads off a HID device.
let hidDetailPropertyKeys = [kIOHIDVersionNumberKey, kIOHIDReportDescriptorKey]

/// The version and the descriptor's fingerprint from a HID device's own
/// properties; its USB interfaces are read from the IORegistry apart.
func hidHardwareDetail(_ properties: [String: Any]) -> HidHardwareDetail {
    let descriptor = (properties[kIOHIDReportDescriptorKey] as? Data).flatMap { $0.isEmpty ? nil : $0 }
    return HidHardwareDetail(versionNumber: properties[kIOHIDVersionNumberKey] as? Int, descriptorSha256: descriptor.map(sha256Hex))
}

/// One interface from its IORegistry entry; nil for an entry missing its
/// number or a code of its triple.
func usbInterface(_ entry: [String: Any]) -> BundleUsbInterface? {
    guard
        let number = entry[UsbInterfaceKey.interfaceNumber] as? Int,
        let interfaceClass = entry[UsbInterfaceKey.interfaceClass] as? Int,
        let subclass = entry[UsbInterfaceKey.interfaceSubclass] as? Int,
        let interfaceProtocol = entry[UsbInterfaceKey.interfaceProtocol] as? Int else { return nil }
    return BundleUsbInterface(
        number: number,
        interfaceClass: UInt8(clamping: interfaceClass),
        subclass: UInt8(clamping: subclass),
        interfaceProtocol: UInt8(clamping: interfaceProtocol)
    )
}

/// A device's interfaces in number order.
func usbInterfaces(_ entries: [[String: Any]]) -> [BundleUsbInterface] {
    entries.compactMap(usbInterface).sorted { $0.number < $1.number }
}

/// Only a device on USB has a USB device above it in the IORegistry.
func looksForUsbDevice(_ transport: HidTransport) -> Bool {
    switch transport {
    case .usb: true
    case .bluetooth, .other, .unknown: false
    }
}

/// What IOKit says of a HID device's hardware: its version and descriptor,
/// and, on USB, its device's interfaces. Nothing is opened.
func hidDeviceDetail(_ device: IOHIDDevice, transport: HidTransport) -> HidHardwareDetail {
    let properties = Dictionary(uniqueKeysWithValues: hidDetailPropertyKeys.compactMap { key in
        IOHIDDeviceGetProperty(device, key as CFString).map { (key, $0 as Any) }
    })
    var detail = hidHardwareDetail(properties)
    detail.interfaces = usbInterfaceEntries(ofHidService: IOHIDDeviceGetService(device), transport: transport).map(usbInterfaces)
    return detail
}

/// The interfaces' entries of a HID device's USB device; nil off USB.
func usbInterfaceEntries(ofHidService service: io_service_t, transport: HidTransport) -> [[String: Any]]? {
    guard looksForUsbDevice(transport) else { return nil }
    return usbInterfaceEntries(above: service)
}

extension HidPadCandidate {
    /// The candidate with its USB device's interfaces, read as it arrived.
    func with(interfaces entries: [[String: Any]]?) -> HidPadCandidate {
        var read = self
        read.detail.interfaces = entries.map(usbInterfaces)
        return read
    }
}
