// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// Which HID devices the Direct reader reads, decided from the device's
// IOKit properties alone so a fake dictionary tests every branch: Nintendo's
// Direct-by-model pads and Valve's Steam Controllers by USB identity (the
// interface that carries the controller), and any other gamepad whose report
// descriptor Dish can decode. Joy-Cons, the charging grip and the devices
// macOS synthesises for GameController are left alone.

import DishCore
import Foundation
import GameController
import IOKit.hid

/// What a lane decodes its reports with.
enum DirectLaneDecoder: Equatable {
    case switchReport(SwitchPadKind)
    case hidGamepad(HidGamepadLayout)
    case steamController
    case steamTriton
}

/// A device the reader will read, and everything the main actor needs to
/// know about it at attach.
struct HidPadCandidate: Equatable {
    let vendorId: UInt16
    let productId: UInt16
    /// IOKit's product string; empty when the device names none.
    let product: String
    let transport: HidTransport
    let model: DirectModel?
    let decoder: DirectLaneDecoder
    /// The report buffer's size: the device's largest input report.
    let reportCapacity: Int
    /// macOS asks for Input Monitoring before opening it: its collections
    /// include a keyboard, a mouse or a touchpad.
    var needsInputMonitoring = false

    /// The model's name, else the device's own, else its USB identity.
    var name: String {
        if let model { return model.name }
        return product.isEmpty ? usbPathKey(vendorId: vendorId, productId: productId) : product
    }

    /// A generic pad's buttons are read in an order only the verified models
    /// were checked against.
    var layoutGuessed: Bool {
        guard case .hidGamepad = decoder else { return false }
        return model?.layoutVerified != true
    }

    var family: PadFamily {
        vendorId == DirectVendor.nintendo ? .nintendo : .other
    }

    /// One slot of a wireless receiver: a pad only while one is connected.
    var receiver: Bool {
        model?.receiver == true
    }

    /// What Dish writes to it: a Steam Controller's configuration.
    var steamPlan: SteamPlan? {
        model.flatMap(DishCore.steamPlan)
    }

    var hardwareId: HidHardwareId {
        HidHardwareId(vendorId: Int(vendorId), productId: Int(productId))
    }
}

enum HidPadLimits {
    /// A Switch pad's full report over USB; a device that names no larger
    /// size still gets this much room.
    static let minimumReportCapacity = 64
    static let slotIdPrefix = "hid:"
}

/// A USB HID interface's number, which IOKit finds on the interface above
/// the device (`kUSBInterfaceNumber`).
let hidInterfaceNumberKey = "bInterfaceNumber"
/// IOHIDFamily marks a device whose collections include a keyboard, a mouse
/// or a touchpad, and `IOHIDDeviceOpen` asks for Input Monitoring before it
/// opens one (`IOHIDDevice.cpp`, `IOHIDDeviceClass.m`).
let hidRequiresInputMonitoringKey = "RequiresTCCAuthorization"

/// The properties the reader reads off a device at attach.
let hidPadPropertyKeys = [
    kIOHIDProductKey, kIOHIDVendorIDKey, kIOHIDProductIDKey, kIOHIDTransportKey, kIOHIDPrimaryUsagePageKey,
    kIOHIDPrimaryUsageKey, kIOHIDDeviceUsagePairsKey, kIOHIDGCSyntheticDeviceKey, kIOHIDMaxInputReportSizeKey,
    kIOHIDReportDescriptorKey, hidInterfaceNumberKey, hidRequiresInputMonitoringKey
]

/// The manager's matching: each model read by its USB identity (every
/// interface of it; the candidate picks the one that carries the pad), and
/// every game usage, all with `GCSyntheticDevice` false.
func hidPadMatching() -> [[String: Any]] {
    let byIdentity = directModels.filter { $0.rule != .whenMacOSCannot }.map { model in
        [kIOHIDVendorIDKey: Int(model.vendorId), kIOHIDProductIDKey: Int(model.productId), kIOHIDGCSyntheticDeviceKey: false]
    }
    return byIdentity + hidCensusMatching()
}

/// The device the reader reads, or nil: a synthetic device, a Nintendo
/// device the model table does not name, a device with no game usage, and
/// a descriptor with nothing gamepad-like in it are all left alone.
func hidPadCandidate(_ properties: [String: Any]) -> HidPadCandidate? {
    let synthetic = properties[kIOHIDGCSyntheticDeviceKey] as? Bool == true
    guard !synthetic else { return nil }
    let vendorId = UInt16(clamping: properties[kIOHIDVendorIDKey] as? Int ?? 0)
    let productId = UInt16(clamping: properties[kIOHIDProductIDKey] as? Int ?? 0)
    let model = directModel(vendorId: vendorId, productId: productId)
    guard let decoder = laneDecoder(model: model, vendorId: vendorId, productId: productId, properties: properties) else { return nil }
    let declaredCapacity = properties[kIOHIDMaxInputReportSizeKey] as? Int ?? 0
    var candidate = HidPadCandidate(
        vendorId: vendorId,
        productId: productId,
        product: properties[kIOHIDProductKey] as? String ?? "",
        transport: hidTransport(properties[kIOHIDTransportKey] as? String),
        model: model,
        decoder: decoder,
        reportCapacity: max(declaredCapacity, HidPadLimits.minimumReportCapacity)
    )
    candidate.needsInputMonitoring = properties[hidRequiresInputMonitoringKey] as? Bool == true
    return candidate
}

/// A Switch model decodes by its table, a Steam Controller by its own
/// decoder on the interface that carries it, any other pad by its descriptor.
private func laneDecoder(model: DirectModel?, vendorId: UInt16, productId: UInt16, properties: [String: Any]) -> DirectLaneDecoder? {
    switch model?.decoder {
    case let .switchReport(kind): .switchReport(kind)
    case .steamController: steamInterface(model, properties) ? .steamController : nil
    case .steamTriton: steamInterface(model, properties) ? .steamTriton : nil
    case .hidGamepad, nil: descriptorDecoder(vendorId: vendorId, productId: productId, properties: properties)
    }
}

private func steamInterface(_ model: DirectModel?, _ properties: [String: Any]) -> Bool {
    guard let model else { return false }
    return steamInterfaceCarriesController(
        model,
        usagePage: properties[kIOHIDPrimaryUsagePageKey] as? Int,
        usage: properties[kIOHIDPrimaryUsageKey] as? Int,
        interfaceNumber: properties[hidInterfaceNumberKey] as? Int
    )
}

private func descriptorDecoder(vendorId: UInt16, productId: UInt16, properties: [String: Any]) -> DirectLaneDecoder? {
    let nintendoLeftToMacOS = vendorId == DirectVendor.nintendo
    guard !nintendoLeftToMacOS, declaresGameUsage(properties) else { return nil }
    guard let descriptor = properties[kIOHIDReportDescriptorKey] as? Data else { return nil }
    let order = hidButtonOrder(vendorId: vendorId, productId: productId)
    return HidGamepadLayout.parse(descriptor: [UInt8](descriptor), order: order).map(DirectLaneDecoder.hidGamepad)
}

private func declaresGameUsage(_ properties: [String: Any]) -> Bool {
    hidUsages(properties).contains { $0.page == hidGenericDesktopPage && hidGameUsages.contains($0.usage) }
}

/// The lane's word in a DEVCAPS line.
func laneKindWord(_ decoder: DirectLaneDecoder) -> String {
    switch decoder {
    case .switchReport(.pro): "switch-pro"
    case .switchReport(.n64): "switch-n64"
    case .switchReport(.snes): "switch-snes"
    case let .hidGamepad(layout): "hid-\(layout.order)"
    case .steamController: "steam-2015"
    case .steamTriton: "steam-2026"
    }
}

/// `hid:057e:2019`, the base of a Direct pad's slot id.
func directSlotBase(vendorId: UInt16, productId: UInt16) -> String {
    HidPadLimits.slotIdPrefix + usbPathKey(vendorId: vendorId, productId: productId)
}

/// The GameController path's ordinal rule: the base when it is free, else
/// the lowest free `#n`.
func lowestFreeSlotId(base: String, taken: Set<String>) -> String {
    guard taken.contains(base) else { return base }
    var ordinal = 1
    while taken.contains("\(base)#\(ordinal)") {
        ordinal += 1
    }
    return "\(base)#\(ordinal)"
}

// MARK: - GameController's answer

/// `GCController.supportsHIDDevice` can say no for a moment after a connect,
/// before the framework has looked at the device, so it is asked again a few
/// times over about 30 ms, as SDL does, and a yes at any point settles it.
enum GameControllerSettle {
    static let checks = 4
    static let intervalMs = 10
}

/// The answer after the `attempt`th check (from 1) said `supported`.
func settledSupport(supported: Bool, attempt: Int) -> GameControllerSupport {
    if supported { return .shows }
    return attempt >= GameControllerSettle.checks ? .doesNotShow : .pending
}
