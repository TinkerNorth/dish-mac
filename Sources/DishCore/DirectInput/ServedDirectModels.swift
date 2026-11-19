// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// The controller database meeting the Mac's own Direct table. The table
// (`directModels`) stays the policy: it is read first, and the database is
// consulted only for an id the table does not name, and only where the Mac
// compiles the record's family for the HID reader. A record whose
// `requires` names a family or an op this build lacks is inert: its name
// and issues show, its input and output are not applied.

import Foundation

/// The family each of the Mac's decoders parses, in the database's ids.
public func controllerFamily(of decoder: DirectDecoder) -> ControllerFamily {
    switch decoder {
    case .switchReport(.pro), .switchReport(.snes): .switchProUsb
    case .switchReport(.n64): .switchN64Usb
    case .hidGamepad: .hid
    case .steamController: .steamController
    case .steamControllerBle: .steamControllerBle
    case .steamTriton: .steamTriton
    case .xusb: .xinput360
    }
}

/// A HID order's name in the database.
public func controllerMapping(of order: HidButtonOrder) -> ControllerMapping {
    switch order {
    case .western: .western
    case .nintendoSwitch: .nintendoSwitch
    case .eightBitDo: .eightBitDo
    case .playStationClassic: .playStationClassic
    }
}

private func hidButtonOrder(of mapping: ControllerMapping) -> HidButtonOrder {
    switch mapping {
    case .western: .western
    case .nintendoSwitch: .nintendoSwitch
    case .eightBitDo: .eightBitDo
    case .playStationClassic: .playStationClassic
    }
}

/// Every family a Mac decoder parses.
public let macCompiledFamilies: Set<ControllerFamily> = [
    .switchProUsb, .switchN64Usb, .hid, .steamController, .steamControllerBle, .steamTriton, .xinput360
]

/// The families a served row may bring to the HID reader. The XUSB reader
/// watches its devices by the table's identities alone (see PARITY.md).
public let servedDirectFamilies: Set<ControllerFamily> = [
    .switchProUsb, .switchN64Usb, .hid, .steamController, .steamControllerBle, .steamTriton
]

/// Schema 1 names no op this build carries.
public let macCompiledOps: Set<String> = []

/// The record names a family or an op this build lacks.
public func recordIsInert(_ record: ControllerRecord) -> Bool {
    let families = Set(macCompiledFamilies.map(\.rawValue))
    let lacksAFamily = !Set(record.requiredFamilies).isSubset(of: families)
    let lacksAnOp = !Set(record.requiredOps).isSubset(of: macCompiledOps)
    let parsesHere = record.family.map(macCompiledFamilies.contains) ?? false
    return lacksAFamily || lacksAnOp || !parsesHere
}

/// The data's rule on the Mac. The probe that gates a pad here is
/// GameController's answer, so `auto` waits for it as `whenOsCannot` does:
/// nothing served takes a pad macOS already reads.
public func macDirectRule(_ rule: ControllerDirectRule) -> DirectRule {
    switch rule {
    case .auto, .whenOsCannot: .whenMacOSCannot
    case .optIn: .optIn
    }
}

private func servedDecoder(_ record: ControllerRecord) -> DirectDecoder? {
    switch record.family {
    case .switchProUsb: .switchReport(.pro)
    case .switchN64Usb: .switchReport(.n64)
    case .hid: .hidGamepad(hidButtonOrder(of: record.mapping ?? .western))
    case .steamController: .steamController
    case .steamControllerBle: .steamControllerBle
    case .steamTriton: .steamTriton
    case .xinput360, .xinput360Wireless, .xboxOneGip, .dualshock4, .dualsense, .stadia, nil: nil
    }
}

/// The Direct model a record gives an id, or nil for an inert record and a
/// family the HID reader does not take from data.
public func servedDirectModel(_ record: ControllerRecord, vendorId: UInt16, productId: UInt16, name: String) -> DirectModel? {
    guard !recordIsInert(record), let family = record.family, servedDirectFamilies.contains(family) else { return nil }
    guard let decoder = servedDecoder(record) else { return nil }
    let nintendo = vendorId == DirectVendor.nintendo
    return DirectModel(
        vendorId: vendorId,
        productId: productId,
        name: name,
        decoder: decoder,
        family: nintendo ? .nintendo : .other,
        rule: macDirectRule(record.directRule),
        gameControllerCarriesOutput: nintendo,
        offersStandard: decoder != .switchReport(.n64),
        receiver: false
    )
}

/// The Direct models the active index adds to the table, by `vid:pid`:
/// every identity the table neither names nor declines.
public struct ServedDirectModels: Equatable, Sendable {
    public static let none = ServedDirectModels(models: [:])

    private let models: [String: DirectModel]

    init(models: [String: DirectModel]) {
        self.models = models
    }

    public init(index: ControllerIndex) {
        var models: [String: DirectModel] = [:]
        for identity in index.identities where models[identity] == nil {
            guard let (vendorId, productId) = parseUsbPathKey(identity) else { continue }
            let compiled = directModel(vendorId: vendorId, productId: productId) != nil
            let declined = directIdentityDeclined(vendorId: vendorId, productId: productId)
            guard !compiled, !declined, let record = index.record(vendorId: vendorId, productId: productId) else { continue }
            let name = index.strings.controllerName(record.id, locale: ControllerStrings.fallbackLocale) ?? record.id
            models[identity] = servedDirectModel(record, vendorId: vendorId, productId: productId, name: name)
        }
        self.models = models
    }

    public func model(vendorId: UInt16, productId: UInt16) -> DirectModel? {
        models[usbPathKey(vendorId: vendorId, productId: productId)]
    }

    /// The served models a reader must match by identity: those it does not
    /// meet through the game usages alone.
    public var matchedByIdentity: [DirectModel] {
        models.keys.sorted().compactMap { models[$0] }.filter { $0.rule != .whenMacOSCannot }
    }
}

/// The table first, then the data.
public func directModel(vendorId: UInt16, productId: UInt16, served: ServedDirectModels) -> DirectModel? {
    directModel(vendorId: vendorId, productId: productId) ?? served.model(vendorId: vendorId, productId: productId)
}

/// "057e:2009" as its two ids; nil for anything else.
public func parseUsbPathKey(_ key: String) -> (UInt16, UInt16)? {
    let parts = key.split(separator: ":")
    guard parts.count == 2, parts.allSatisfy({ $0.count == 4 }) else { return nil }
    guard let vendorId = UInt16(parts[0], radix: 16), let productId = UInt16(parts[1], radix: 16) else { return nil }
    return (vendorId, productId)
}
