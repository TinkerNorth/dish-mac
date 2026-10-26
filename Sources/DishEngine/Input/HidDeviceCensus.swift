// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Foundation
import GameController
import IOKit.hid

/// A HID device's vendor and product ids, as USB and Bluetooth both report them.
package struct HidHardwareId: Hashable {
    package let vendorId: Int
    package let productId: Int

    package init(vendorId: Int, productId: Int) {
        self.vendorId = vendorId
        self.productId = productId
    }
}

/// How a HID device reaches the Mac, from IOKit's `Transport` property.
package enum HidTransport: Equatable {
    case usb
    case bluetooth
    /// A transport IOKit names that is neither (SPI, I2C, Virtual), in IOKit's own word.
    case other(String)
    /// The device names none.
    case unknown
}

/// One game device on the Mac's HID bus, and whether GameController takes it.
package struct HidDeviceFacts: Equatable, Identifiable {
    /// The IORegistry entry id, stable while the device stays attached.
    package let id: UInt64
    package let name: String
    package let hardwareId: HidHardwareId
    package let transport: HidTransport
    /// `GCController.supportsHIDDevice`: the framework will vend a controller for it.
    package let claimedByGameController: Bool

    package init(id: UInt64, name: String, hardwareId: HidHardwareId, transport: HidTransport, claimedByGameController: Bool) {
        self.id = id
        self.name = name
        self.hardwareId = hardwareId
        self.transport = transport
        self.claimedByGameController = claimedByGameController
    }
}

/// HID usage page Generic Desktop, and the usages on it that are game devices:
/// Joystick, GamePad and MultiAxisController.
let hidGenericDesktopPage = 0x01
let hidGameUsages: Set = [0x04, 0x05, 0x08]

/// The IOHIDManager's matching, one dictionary per game usage. Each asks for
/// `GCSyntheticDevice` false, which Apple calls the only supported way to
/// leave out the Xbox-shaped devices macOS 14 and later synthesise for
/// GameController's pads.
func hidCensusMatching() -> [[String: Any]] {
    hidGameUsages.sorted().map { usage in
        [kIOHIDDeviceUsagePageKey: hidGenericDesktopPage, kIOHIDDeviceUsageKey: usage, kIOHIDGCSyntheticDeviceKey: false]
    }
}

/// The properties the census reads off a device.
let hidCensusPropertyKeys = [
    kIOHIDProductKey, kIOHIDVendorIDKey, kIOHIDProductIDKey, kIOHIDTransportKey, kIOHIDPrimaryUsagePageKey,
    kIOHIDPrimaryUsageKey, kIOHIDDeviceUsagePairsKey, kIOHIDGCSyntheticDeviceKey
]

/// One device's facts from its properties: nil for a synthetic device and
/// for one with no game usage, whatever the matching let through.
func hidDeviceFacts(id: UInt64, properties: [String: Any], claimed: Bool) -> HidDeviceFacts? {
    let synthetic = properties[kIOHIDGCSyntheticDeviceKey] as? Bool == true
    let isGameDevice = hidUsages(properties).contains { $0.page == hidGenericDesktopPage && hidGameUsages.contains($0.usage) }
    guard !synthetic, isGameDevice else { return nil }
    let hardwareId = HidHardwareId(
        vendorId: properties[kIOHIDVendorIDKey] as? Int ?? 0,
        productId: properties[kIOHIDProductIDKey] as? Int ?? 0
    )
    return HidDeviceFacts(
        id: id,
        name: properties[kIOHIDProductKey] as? String ?? "",
        hardwareId: hardwareId,
        transport: hidTransport(properties[kIOHIDTransportKey] as? String),
        claimedByGameController: claimed
    )
}

/// Every usage a device declares: its usage pairs and its primary usage.
func hidUsages(_ properties: [String: Any]) -> [(page: Int, usage: Int)] {
    let pairs = properties[kIOHIDDeviceUsagePairsKey] as? [[String: Any]] ?? []
    let listed = pairs.compactMap { hidUsage($0, pageKey: kIOHIDDeviceUsagePageKey, usageKey: kIOHIDDeviceUsageKey) }
    let primary = hidUsage(properties, pageKey: kIOHIDPrimaryUsagePageKey, usageKey: kIOHIDPrimaryUsageKey)
    return listed + [primary].compactMap(\.self)
}

private func hidUsage(_ properties: [String: Any], pageKey: String, usageKey: String) -> (page: Int, usage: Int)? {
    guard let page = properties[pageKey] as? Int, let usage = properties[usageKey] as? Int else { return nil }
    return (page, usage)
}

func hidTransport(_ word: String?) -> HidTransport {
    guard let word, !word.isEmpty else { return .unknown }
    if word == kIOHIDTransportUSBValue { return .usb }
    if word.hasPrefix(kIOHIDTransportBluetoothValue) { return .bluetooth }
    return .other(word)
}

/// The ids of the one device GameController claims under the pad's name;
/// nil when no device, or devices with different ids, carry it.
func hardwareId(forPadNamed name: String, in devices: [HidDeviceFacts]) -> HidHardwareId? {
    let wanted = name.trimmingCharacters(in: .whitespaces).lowercased()
    let carriers = devices.filter { $0.claimedByGameController && $0.name.trimmingCharacters(in: .whitespaces).lowercased() == wanted }
    let ids = Set(carriers.map(\.hardwareId))
    return ids.count == 1 ? ids.first : nil
}

// MARK: - The seam

/// The Mac's HID game devices. Tests hand in a fake; the IOKit one watches
/// an IOHIDManager while the Diagnostics page shows.
@MainActor
protocol HidCensusReading: AnyObject {
    /// Starts watching; `changed` runs on the main thread when a device is
    /// matched or removed.
    func start(changed: @escaping () -> Void)
    func stop()
    /// The game devices present, by name; empty while stopped.
    func devices() -> [HidDeviceFacts]
}

/// An IOHIDManager over the game usages, never opened: enumeration needs no
/// open, so no device is touched and no permission is asked. Scheduled on
/// the main run loop while started.
@MainActor
final class IOKitHidCensus: HidCensusReading {

    private var manager: IOHIDManager?
    private var changed: () -> Void = {}
    /// `supportsHIDDevice` "is not cheap, be sure to cache the result"
    /// (GCController.h): each device's answer is kept while it stays.
    private var claims: [UInt64: Bool] = [:]

    /// Nothing is created until `start`, so a default argument may build one.
    nonisolated init() {}

    /// The manager's callbacks hold the census retained until `stop`, so a
    /// callback never reaches a freed one.
    func start(changed: @escaping () -> Void) {
        guard manager == nil else { return }
        self.changed = changed
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let context = Unmanaged.passRetained(self).toOpaque()
        IOHIDManagerSetDeviceMatchingMultiple(manager, hidCensusMatching() as CFArray)
        IOHIDManagerRegisterDeviceMatchingCallback(manager, hidCensusDeviceChanged, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, hidCensusDeviceChanged, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        self.manager = manager
    }

    func stop() {
        guard let manager else { return }
        IOHIDManagerRegisterDeviceMatchingCallback(manager, nil, nil)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, nil, nil)
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        self.manager = nil
        claims = [:]
        Unmanaged.passUnretained(self).release()
    }

    func devices() -> [HidDeviceFacts] {
        guard let manager, let present = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return [] }
        let facts = present.compactMap(facts(of:))
        let ids = Set(facts.map(\.id))
        claims = claims.filter { ids.contains($0.key) }
        return facts.sorted { ($0.name, $0.id) < ($1.name, $1.id) }
    }

    fileprivate func deviceChanged() {
        changed()
    }

    private func facts(of device: IOHIDDevice) -> HidDeviceFacts? {
        let id = registryId(of: device)
        let properties = Dictionary(uniqueKeysWithValues: hidCensusPropertyKeys.compactMap { key in
            IOHIDDeviceGetProperty(device, key as CFString).map { (key, $0 as Any) }
        })
        return hidDeviceFacts(id: id, properties: properties, claimed: claim(device, id: id))
    }

    private func claim(_ device: IOHIDDevice, id: UInt64) -> Bool {
        if let known = claims[id] { return known }
        let fresh = GCController.supportsHIDDevice(device)
        claims[id] = fresh
        return fresh
    }

    /// IOKit hands the id back through an out-parameter.
    private func registryId(of device: IOHIDDevice) -> UInt64 {
        var id: UInt64 = 0
        let status = IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(device), &id)
        return status == KERN_SUCCESS ? id : 0
    }
}

/// The manager's match and removal callback; it runs on the main run loop.
private func hidCensusDeviceChanged(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    device: IOHIDDevice
) {
    guard let context else { return }
    let census = Unmanaged<IOKitHidCensus>.fromOpaque(context).takeUnretainedValue()
    MainActor.assumeIsolated { census.deviceChanged() }
}
