// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// The Mac's conditions that explain latency and feedback complaints, read
// once when a support report is made: the battery, the thermal state, Low
// Power Mode, the Wi-Fi link's band, signal and rate, and whether macOS
// lists a USB host controller. CoreWLAN's network name and BSSID are never
// read.

import CoreWLAN
import DishCore
import Foundation
import IOKit

/// A gateway: one blocking read, on the caller's queue.
package struct DeviceConditionsReading {
    let read: @Sendable () -> BundleDeviceConditions

    /// What a composition root outside the app reads: nothing.
    package static let none = DeviceConditionsReading(read: { BundleDeviceConditions.unknown })

    package static let live = DeviceConditionsReading(read: { liveDeviceConditions() })
}

@Sendable
private func liveDeviceConditions() -> BundleDeviceConditions {
    let process = ProcessInfo.processInfo
    return BundleDeviceConditions(
        battery: HostBattery.snapshot().flatMap(bundleBattery),
        thermal: bundleThermal(rawValue: process.thermalState.rawValue),
        powerSave: process.isLowPowerModeEnabled,
        wifi: liveWifi(),
        usbHost: usbHost(controllerCount: usbHostControllerCount())
    )
}

/// The class every Mac xHCI controller derives from (`AppleUSBXHCI` and
/// its subclasses): three on the Apple silicon Mac this was measured on.
let usbHostControllerClass = "AppleUSBHostController"

/// The USB host controllers IOKit lists; nil when it gave no answer. A
/// virtual machine without a USB controller lists none.
func usbHostControllerCount() -> Int? {
    var iterator: io_iterator_t = 0
    let status = IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(usbHostControllerClass), &iterator)
    guard status == KERN_SUCCESS else { return nil }
    defer { IOObjectRelease(iterator) }
    let services = Array(sequence(state: iterator) { iterator -> io_service_t? in
        let service = IOIteratorNext(iterator)
        return service == 0 ? nil : service
    })
    for service in services {
        IOObjectRelease(service)
    }
    return services.count
}

/// A battery with no usable capacity yet says nothing.
func bundleBattery(_ snapshot: HostBattery.Snapshot) -> BundleBattery? {
    snapshot.percentage.map { BundleBattery(level: $0, charging: snapshot.state == .charging) }
}

private func liveWifi() -> BundleWifi? {
    guard let interface = CWWiFiClient.shared().interface() else { return nil }
    return bundleWifi(
        bandGHz: interface.wlanChannel().flatMap { wifiBand($0.channelBand) },
        rssiDbm: interface.rssiValue(),
        transmitRateMbps: interface.transmitRate()
    )
}

func wifiBand(_ band: CWChannelBand) -> String? {
    switch band {
    case .band2GHz: "2.4"
    case .band5GHz: "5"
    case .band6GHz: "6"
    case .bandUnknown: nil
    @unknown default: nil
    }
}
