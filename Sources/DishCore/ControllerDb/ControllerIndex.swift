// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// The immutable index from `vid:pid` to record (section 6.2): the bundled
// set, or the cached download when its version is greater. A newer version
// replaces the whole set; records are never merged one by one.

import Foundation

/// Where the set in force came from.
public enum ControllerDbOrigin: String, Equatable, Sendable {
    case bundled
    case cache
}

public struct ControllerIndex: Equatable, Sendable {
    public let dbVersion: Int
    public let source: ControllerDbOrigin
    public let strings: ControllerStrings
    private let byUsb: [String: ControllerRecord]
    private let byBluetooth: [String: ControllerRecord]

    /// The first record to name an id keeps it.
    public init(_ set: ControllerDbSet, source: ControllerDbOrigin) {
        dbVersion = set.dbVersion
        self.source = source
        strings = set.strings
        var usb: [String: ControllerRecord] = [:]
        var bluetooth: [String: ControllerRecord] = [:]
        for record in set.database.records {
            for id in record.usb where usb[id] == nil {
                usb[id] = record
            }
            for id in record.bluetooth where bluetooth[id] == nil {
                bluetooth[id] = record
            }
        }
        byUsb = usb
        byBluetooth = bluetooth
    }

    /// The record for the pad's identity on its transport, else on the
    /// other one: a pad whose transport is unknown is looked up on both.
    public func record(vendorId: UInt16, productId: UInt16, transport: ControllerTransport? = nil) -> ControllerRecord? {
        let key = usbPathKey(vendorId: vendorId, productId: productId)
        switch transport {
        case .bluetooth: return byBluetooth[key] ?? byUsb[key]
        case .usb, nil: return byUsb[key] ?? byBluetooth[key]
        }
    }

    /// Every identity the index answers for, USB first.
    public var identities: [String] {
        byUsb.keys.sorted() + byBluetooth.keys.sorted()
    }
}

/// The cached download only when it is newer than what the app was built with.
public func activeControllerIndex(bundled: ControllerDbSet, cached: ControllerDbSet?) -> ControllerIndex {
    guard let cached, cached.dbVersion > bundled.dbVersion else { return ControllerIndex(bundled, source: .bundled) }
    return ControllerIndex(cached, source: .cache)
}
