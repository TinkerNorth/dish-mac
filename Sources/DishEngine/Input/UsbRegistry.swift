// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// The IORegistry's USB entries, read without opening anything. IOUSBHost
// hands a device's descriptors only to a client holding an exclusive
// session on it (IOUSBHostObject.h), and macOS's drivers hold a pad's, so
// what Dish reports of a pad's USB device comes from the properties the
// registry publishes for each IOUSBHostDevice and IOUSBHostInterface.

import Foundation
import IOKit
import IOUSBHost

/// A HID device's USB device sits two levels up (the HID driver's parent is
/// its IOUSBHostInterface, whose parent is the IOUSBHostDevice); one more
/// level is searched before giving up.
let usbDeviceSearchLevels = 3

/// The keys an interface's entry is read under.
let usbInterfaceEntryKeys = [
    UsbInterfaceKey.interfaceNumber, UsbInterfaceKey.interfaceClass, UsbInterfaceKey.interfaceSubclass,
    UsbInterfaceKey.interfaceProtocol
]

/// Every object an iterator hands over, each retained for the caller.
func drainIterator(_ iterator: io_iterator_t) -> [io_object_t] {
    Array(sequence(state: iterator) { iterator in
        let object = IOIteratorNext(iterator)
        return object == 0 ? nil : object
    })
}

func registryValue(_ entry: io_registry_entry_t, _ key: String) -> Any? {
    IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
}

func registryProperties(_ entry: io_registry_entry_t, keys: [String]) -> [String: Any] {
    Dictionary(uniqueKeysWithValues: keys.compactMap { key in registryValue(entry, key).map { (key, $0) } })
}

/// The interfaces' entries of the USB device at or above `entry`; nil when
/// none is within reach (a Bluetooth or SPI device, or a virtual one that
/// calls itself USB).
func usbInterfaceEntries(above entry: io_registry_entry_t) -> [[String: Any]]? {
    IOObjectRetain(entry)
    guard let device = usbDeviceSearch(entry, levelsLeft: usbDeviceSearchLevels) else { return nil }
    defer { IOObjectRelease(device) }
    return usbInterfaceEntries(of: device)
}

/// The USB device's own entry at or above `entry`, read under `keys`.
func usbDeviceEntry(above entry: io_registry_entry_t, keys: [String]) -> [String: Any]? {
    IOObjectRetain(entry)
    guard let device = usbDeviceSearch(entry, levelsLeft: usbDeviceSearchLevels) else { return nil }
    defer { IOObjectRelease(device) }
    return registryProperties(device, keys: keys)
}

/// Takes `entry`'s reference: the entry itself when it is a USB device,
/// else its parent's search, one level fewer.
private func usbDeviceSearch(_ entry: io_registry_entry_t, levelsLeft: Int) -> io_registry_entry_t? {
    guard IOObjectConformsTo(entry, kIOUSBHostDeviceClassName) == 0 else { return entry }
    defer { IOObjectRelease(entry) }
    var parent: io_registry_entry_t = 0
    let found = levelsLeft > 0 && IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent) == KERN_SUCCESS
    return found ? usbDeviceSearch(parent, levelsLeft: levelsLeft - 1) : nil
}

/// Each IOUSBHostInterface under the device, as its number and triple.
private func usbInterfaceEntries(of device: io_registry_entry_t) -> [[String: Any]] {
    var iterator: io_iterator_t = 0
    guard IORegistryEntryGetChildIterator(device, kIOServicePlane, &iterator) == KERN_SUCCESS else { return [] }
    defer { IOObjectRelease(iterator) }
    let children = drainIterator(iterator)
    defer {
        for child in children {
            IOObjectRelease(child)
        }
    }
    let interfaces = children.filter { IOObjectConformsTo($0, kIOUSBHostInterfaceClassName) != 0 }
    return interfaces.map { registryProperties($0, keys: usbInterfaceEntryKeys) }
}
