// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// "Report a problem" and "Ask a question": the person's category, their own
// words and the controller it concerns, which go first in the mail and into
// the diagnostics bundle as `report`; and the Mac's own conditions that
// explain latency and feedback complaints, never with a network name.

import Foundation

public enum SupportReportCategory: String, CaseIterable, Equatable, Sendable {
    case notRecognised
    case noFeedback
    case connection
    case audio
    case other
    case question
}

public struct SupportReport: Equatable, Sendable {
    public let category: SupportReportCategory
    public let text: String
    /// The record id, or the slot's product string, or nil.
    public let controller: String?

    public init(category: SupportReportCategory, text: String, controller: String?) {
        self.category = category
        self.text = text
        self.controller = controller
    }
}

/// The controller a report names: its record when the data knows it, else
/// what the pad calls itself.
public func reportedController(record: ControllerRecord?, product: String) -> String {
    record?.id ?? product
}

/// The mail's subject. Only the category is in the person's language: the
/// rest stays English in every locale, so support's mailbox can filter on
/// the prefix.
public func supportMailSubject(category: String, version: String, model: String) -> String {
    "Dish support: \(category) · Dish for macOS \(version) on \(model)"
}

/// The person's words as they go into the mail and the file: trimmed, and
/// nothing else changed.
public func reportText(_ typed: String) -> String {
    typed.trimmingCharacters(in: .whitespacesAndNewlines)
}

// MARK: - Device conditions

public enum BundleThermal: String, Equatable, Sendable {
    case nominal
    case fair
    case serious
    case critical
}

/// `ProcessInfo.ThermalState`'s raw value in the contract's words; nil for
/// one a newer macOS adds.
public func bundleThermal(rawValue: Int) -> BundleThermal? {
    switch rawValue {
    case 0: .nominal
    case 1: .fair
    case 2: .serious
    case 3: .critical
    default: nil
    }
}

public struct BundleBattery: Equatable, Sendable {
    public let level: Int
    public let charging: Bool

    public init(level: Int, charging: Bool) {
        self.level = level
        self.charging = charging
    }
}

/// The Wi-Fi link's band, signal and rate; never its name.
public struct BundleWifi: Equatable, Sendable {
    public let band: String?
    public let rssiDbm: Int
    public let linkSpeedMbps: Int?

    public init(band: String?, rssiDbm: Int, linkSpeedMbps: Int?) {
        self.band = band
        self.rssiDbm = rssiDbm
        self.linkSpeedMbps = linkSpeedMbps
    }
}

/// What CoreWLAN reports of the interface, before it is read as a link. A
/// zero RSSI is CoreWLAN's "not associated".
public func bundleWifi(bandGHz: String?, rssiDbm: Int, transmitRateMbps: Double) -> BundleWifi? {
    guard rssiDbm != 0 else { return nil }
    let rate = transmitRateMbps > 0 ? Int(transmitRateMbps.rounded()) : nil
    return BundleWifi(band: bandGHz, rssiDbm: rssiDbm, linkSpeedMbps: rate)
}

public struct BundleDeviceConditions: Equatable, Sendable {
    /// Nil on a Mac without a battery.
    public let battery: BundleBattery?
    public let thermal: BundleThermal?
    public let powerSave: Bool?
    /// Nil when Wi-Fi is off or not associated.
    public let wifi: BundleWifi?

    public init(battery: BundleBattery?, thermal: BundleThermal?, powerSave: Bool?, wifi: BundleWifi?) {
        self.battery = battery
        self.thermal = thermal
        self.powerSave = powerSave
        self.wifi = wifi
    }

    /// Nothing read: what a composition root outside the app has.
    public static let unknown = BundleDeviceConditions(battery: nil, thermal: nil, powerSave: nil, wifi: nil)
}

// MARK: - The encoded shape

struct SupportReportFile: Encodable {
    let category: String
    let text: String
    let controller: String?

    private enum CodingKeys: String, CodingKey { case category, text, controller }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(category, forKey: .category)
        try container.encode(text, forKey: .text)
        try container.encode(controller, forKey: .controller)
    }
}

func supportReportFile(_ report: SupportReport) -> SupportReportFile {
    SupportReportFile(category: report.category.rawValue, text: report.text, controller: report.controller)
}

struct WifiFile: Encodable {
    let band: String?
    let rssiDbm: Int
    let linkSpeedMbps: Int?

    private enum CodingKeys: String, CodingKey { case band, rssiDbm, linkSpeedMbps }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(band, forKey: .band)
        try container.encode(rssiDbm, forKey: .rssiDbm)
        try container.encode(linkSpeedMbps, forKey: .linkSpeedMbps)
    }
}

struct BatteryFile: Encodable {
    let level: Int
    let charging: Bool
}
