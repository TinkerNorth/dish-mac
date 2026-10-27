// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import DishEngine
import Foundation

/// "057e:2019": four lowercase hex digits each, as every Dish client prints a
/// vendor and product id.
func hardwareIdText(_ id: HidHardwareId) -> String {
    String(format: "%04x:%04x", id.vendorId, id.productId)
}

/// How the device reaches the Mac; a transport IOKit names that is neither
/// USB nor Bluetooth reads in IOKit's word.
func transportText(_ transport: HidTransport, words: L10n = .app) -> String {
    switch transport {
    case .usb: words.usb
    case .bluetooth: words.bluetooth
    case let .other(word): word
    case .unknown: words.unknown
    }
}

/// The section Android calls "Other input devices": a game device on the
/// HID bus GameController does not claim, so Dish cannot read it.
struct OtherInputDevicesState: Equatable {
    let title: String
    let note: String
    let cards: [DiagnosticsCardState]
}

/// Nil while GameController claims every game device, so the section only
/// shows when it has something to say.
func otherInputDevicesState(_ devices: [HidDeviceFacts], words: L10n = .app) -> OtherInputDevicesState? {
    let unclaimed = devices.filter { !$0.claimedByGameController }
    guard !unclaimed.isEmpty else { return nil }
    let cards = unclaimed.map { inputDeviceCard($0, words: words) }
    return OtherInputDevicesState(title: words.otherInputDevices, note: words.otherInputDevicesNote, cards: cards)
}

/// The device's product name, else the word for unknown.
func inputDeviceCard(_ device: HidDeviceFacts, words: L10n = .app) -> DiagnosticsCardState {
    DiagnosticsCardState(
        id: "hid:\(device.id)",
        title: device.name.isEmpty ? words.unknown : device.name,
        dot: nil,
        chip: nil,
        lines: inputDeviceLines(device, words: words),
        inspects: nil,
        supportKey: supportTarget(of: device).deviceKey
    )
}

/// The device by its USB identity, which the census always knows.
func supportTarget(of device: HidDeviceFacts) -> SupportTarget {
    .usb(vendorId: UInt16(clamping: device.hardwareId.vendorId), productId: UInt16(clamping: device.hardwareId.productId))
}

/// Why Dish leaves it out, its hardware ID and how it is connected.
func inputDeviceLines(_ device: HidDeviceFacts, words: L10n = .app) -> [FactLine] {
    [
        FactLine(key: words.status, value: words.notClaimedByGameController),
        FactLine(key: words.hardwareId, value: hardwareIdText(device.hardwareId)),
        FactLine(key: words.connection, value: transportText(device.transport, words: words))
    ]
}
