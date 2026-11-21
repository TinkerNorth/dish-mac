// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// A USB pad's raw descriptors for the diagnostics file's fingerprint: its
// device descriptor, then each configuration descriptor in index order, as
// dish-android's `getRawDescriptors()`, Linux's sysfs `descriptors` and the
// Windows hub request return them. Nothing opens the pad: the configuration
// descriptors come from IOUSBLib's device interface, which IOUSBLib.h says
// "points to the data as received from the USB bus" and "the device does
// not have to be open to use", and the device descriptor is rebuilt from
// the fields the IORegistry publishes for the IOUSBHostDevice, each one the
// descriptor's own.

import DishCore
import Foundation
import IOKit
import IOKit.usb
import IOUSBHost

/// A USB device as the IORegistry lists it above a HID device or an
/// interface: its entry's id and its interfaces' entries.
struct UsbDeviceListing {
    let registryId: UInt64
    let interfaces: [[String: Any]]
}

/// A USB device's raw descriptors: its device descriptor and each
/// configuration descriptor in index order.
package struct UsbRawDescriptors: Equatable {
    package let device: [UInt8]
    package let configurations: [[UInt8]]
    /// `kUSBCurrentConfiguration`: the `bConfigurationValue` in force.
    package let currentConfiguration: Int?

    package init(device: [UInt8], configurations: [[UInt8]], currentConfiguration: Int? = nil) {
        self.device = device
        self.configurations = configurations
        self.currentConfiguration = currentConfiguration
    }

    /// The bytes the fingerprint is taken of.
    package var bytes: [UInt8] {
        device + configurations.joined()
    }
}

/// A USB device's raw descriptors by its IORegistry entry id: nil where
/// IOKit hands none over.
@MainActor
protocol UsbDescriptorReading: AnyObject {
    func rawDescriptors(ofUsbDevice registryId: UInt64) -> UsbRawDescriptors?
}

/// IOUSBLib's device user client, `kIOUSBDeviceUserClientTypeID` in IOUSBLib.h.
let usbDeviceUserClientType = CFUUIDGetConstantUUIDWithBytes(
    nil, 0x9D, 0xC7, 0xB7, 0x80, 0x9E, 0xC0, 0x11, 0xD4, 0xA5, 0x4F, 0x00, 0x0A, 0x27, 0x05, 0x28, 0x61
)
/// `kIOCFPlugInInterfaceID` in IOCFPlugIn.h.
let ioCFPlugInInterfaceType = CFUUIDGetConstantUUIDWithBytes(
    nil, 0xC2, 0x44, 0xE8, 0x58, 0x10, 0x9C, 0x11, 0xD4, 0x91, 0xD4, 0x00, 0x50, 0xE4, 0xC6, 0x42, 0x6F
)
/// `kIOUSBDeviceInterfaceID100` in IOUSBLib.h: the version every later one
/// extends, which carries the two calls read here.
let usbDeviceInterfaceType = CFUUIDGetConstantUUIDWithBytes(
    nil, 0x5C, 0x81, 0x87, 0xD0, 0x9E, 0xF3, 0x11, 0xD4, 0x8B, 0x45, 0x00, 0x0A, 0x27, 0x05, 0x28, 0x61
)

/// One field of the device descriptor: its IORegistry key and its width.
struct UsbDescriptorField {
    let key: String
    let bytes: Int
}

/// The device descriptor after its length and type, field by field, in the
/// order USB 2.0's table 9-8 lays them out.
let usbDeviceDescriptorFields = [
    UsbDescriptorField(key: "bcdUSB", bytes: 2), UsbDescriptorField(key: "bDeviceClass", bytes: 1),
    UsbDescriptorField(key: "bDeviceSubClass", bytes: 1), UsbDescriptorField(key: "bDeviceProtocol", bytes: 1),
    UsbDescriptorField(key: "bMaxPacketSize0", bytes: 1), UsbDescriptorField(key: "idVendor", bytes: 2),
    UsbDescriptorField(key: "idProduct", bytes: 2), UsbDescriptorField(key: "bcdDevice", bytes: 2),
    UsbDescriptorField(key: "iManufacturer", bytes: 1), UsbDescriptorField(key: "iProduct", bytes: 1),
    UsbDescriptorField(key: "iSerialNumber", bytes: 1), UsbDescriptorField(key: "bNumConfigurations", bytes: 1)
]

/// A device descriptor's length and type.
private let usbDeviceDescriptorHead: [UInt8] = [0x12, 0x01]

/// The configuration in force, as IOUSBHostFamilyDefinitions.h names it.
let usbCurrentConfigurationKey = "kUSBCurrentConfiguration"

/// The eighteen bytes of the device descriptor, its words little-endian as
/// on the bus; nil when the IORegistry lacks a field.
func usbDeviceDescriptor(_ fields: [String: Any]) -> [UInt8]? {
    let values = usbDeviceDescriptorFields.map { field in (fields[field.key] as? Int).map { (field, $0) } }
    guard values.allSatisfy({ $0 != nil }) else { return nil }
    let body = values.compactMap(\.self).flatMap { field, value in
        (0 ..< field.bytes).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) }
    }
    return usbDeviceDescriptorHead + body
}

/// USB 2.0's descriptor types and the interrupt transfer type.
private enum UsbDescriptorType {
    static let interface: UInt8 = 0x04
    static let endpoint: UInt8 = 0x05
    static let interruptTransfer: UInt8 = 0x03
    static let transferTypeMask: UInt8 = 0x03
    static let directionIn: UInt8 = 0x80
}

/// A configuration descriptor's `bConfigurationValue` sits at offset 5.
private let configurationValueOffset = 5

/// One descriptor within a configuration: its type and its bytes.
private struct UsbDescriptorChunk {
    let type: UInt8
    let bytes: ArraySlice<UInt8>
}

/// A configuration's descriptors one after another, each by its own
/// length; a length that could not hold its type ends the walk.
private func descriptorChunks(_ configuration: [UInt8]) -> [UsbDescriptorChunk] {
    var chunks: [UsbDescriptorChunk] = []
    var start = 0
    while start + 1 < configuration.count, configuration[start] >= 2 {
        let end = min(start + Int(configuration[start]), configuration.count)
        chunks.append(UsbDescriptorChunk(type: configuration[start + 1], bytes: configuration[start ..< end]))
        start = end
    }
    return chunks
}

/// The endpoints of one interface, at alternate setting 0, in the
/// configuration in force: its first interrupt IN and its first interrupt
/// OUT. Nil when it has no interrupt IN.
func interruptEndpoints(_ descriptors: UsbRawDescriptors, interfaceNumber: Int) -> BundleEndpoints? {
    let inForce = descriptors.configurations.first { configuration in
        configuration.count > configurationValueOffset && Int(configuration[configurationValueOffset]) == descriptors.currentConfiguration
    }
    guard let configuration = inForce ?? descriptors.configurations.first else { return nil }
    let addresses = endpointAddresses(descriptorChunks(configuration), interfaceNumber: interfaceNumber)
    guard let input = addresses.first(where: { $0 & UsbDescriptorType.directionIn != 0 }) else { return nil }
    return BundleEndpoints(input: input, output: addresses.first { $0 & UsbDescriptorType.directionIn == 0 })
}

/// The interrupt endpoints' addresses that follow the interface's own
/// descriptor, until the next interface descriptor.
private func endpointAddresses(_ chunks: [UsbDescriptorChunk], interfaceNumber: Int) -> [UInt8] {
    let interfaceStart = chunks.firstIndex { chunk in
        let bytes = Array(chunk.bytes)
        return chunk.type == UsbDescriptorType.interface && bytes.count >= 4 && Int(bytes[2]) == interfaceNumber && bytes[3] == 0
    }
    guard let interfaceStart else { return [] }
    let following = chunks[(interfaceStart + 1)...].prefix { $0.type != UsbDescriptorType.interface }
    return following.compactMap { chunk in
        let bytes = Array(chunk.bytes)
        guard chunk.type == UsbDescriptorType.endpoint, bytes.count >= 4 else { return nil }
        let interrupt = bytes[3] & UsbDescriptorType.transferTypeMask == UsbDescriptorType.interruptTransfer
        return interrupt ? bytes[2] : nil
    }
}

/// The IOKit reader: the IOUSBHostDevice by its registry id, its device
/// descriptor rebuilt from its entry, its configurations through IOUSBLib.
@MainActor
final class IOKitUsbDescriptorReader: UsbDescriptorReading {
    nonisolated init() {}

    func rawDescriptors(ofUsbDevice registryId: UInt64) -> UsbRawDescriptors? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IORegistryEntryIDMatching(registryId))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard IOObjectConformsTo(service, kIOUSBHostDeviceClassName) != 0 else { return nil }
        let fields = registryProperties(service, keys: usbDeviceDescriptorFields.map(\.key) + [usbCurrentConfigurationKey])
        guard let device = usbDeviceDescriptor(fields), let configurations = usbConfigurationDescriptors(service) else { return nil }
        let current = fields[usbCurrentConfigurationKey] as? Int
        return UsbRawDescriptors(device: device, configurations: configurations, currentConfiguration: current)
    }
}

/// Every configuration descriptor in index order, through IOUSBLib's device
/// interface, which is never opened; nil when any one is missing.
private func usbConfigurationDescriptors(_ service: io_service_t) -> [[UInt8]]? {
    var plugIn: UnsafeMutablePointer<UnsafeMutablePointer<IOCFPlugInInterface>?>?
    var score: Int32 = 0
    let created = IOCreatePlugInInterfaceForService(service, usbDeviceUserClientType, ioCFPlugInInterfaceType, &plugIn, &score)
    guard created == KERN_SUCCESS, let plugIn, let plugInTable = plugIn.pointee?.pointee else { return nil }
    defer { releaseInterface(plugInTable.Release, plugIn) }
    var queried: LPVOID?
    let answer = plugInTable.QueryInterface(plugIn, CFUUIDGetUUIDBytes(usbDeviceInterfaceType), &queried)
    guard answer == S_OK, let queried else { return nil }
    let device = queried.assumingMemoryBound(to: UnsafeMutablePointer<IOUSBDeviceInterface100>?.self)
    guard let table = device.pointee?.pointee else { return nil }
    defer { releaseInterface(table.Release, queried) }
    var count: UInt8 = 0
    guard table.GetNumberOfConfigurations(queried, &count) == kIOReturnSuccess else { return nil }
    let read = (0 ..< count).map { configurationDescriptor(table, queried, index: $0) }
    return read.allSatisfy { $0 != nil } ? read.compactMap(\.self) : nil
}

/// One configuration descriptor, its whole `wTotalLength`.
private func configurationDescriptor(_ table: IOUSBDeviceInterface100, _ device: LPVOID, index: UInt8) -> [UInt8]? {
    var descriptor: IOUSBConfigurationDescriptorPtr?
    guard table.GetConfigurationDescriptorPtr(device, index, &descriptor) == kIOReturnSuccess, let descriptor else { return nil }
    let length = Int(UInt16(littleEndian: descriptor.pointee.wTotalLength))
    return Array(UnsafeRawBufferPointer(start: descriptor, count: length))
}

/// Gives back a COM interface IOKit handed over.
private func releaseInterface(_ release: (@convention(c) (UnsafeMutableRawPointer?) -> ULONG)?, _ object: UnsafeMutableRawPointer?) {
    // The count left after the release says nothing the reader acts on.
    _ = release?(object)
}
