// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// "Help support this controller": a guided press sequence over a pad Dish
// cannot read well, recording the distinct input reports seen at each step,
// and the plain-text report built from them for the user to paste into an
// issue. Nothing here sends anything anywhere.

import Foundation

/// One stop of the sequence. The report names each in English, since it is
/// written for whoever reads the issue.
public enum SupportStep: CaseIterable, Equatable, Sendable {
    case atRest
    case pressA
    case pressB
    case pressX
    case pressY
    case leftShoulder
    case rightShoulder
    case leftTrigger
    case rightTrigger
    case select
    case start
    case dpadUp
    case leftStickUp
    case rightStickUp

    public var reportName: String {
        switch self {
        case .atRest: "At rest"
        case .pressA: "Press A"
        case .pressB: "Press B"
        case .pressX: "Press X"
        case .pressY: "Press Y"
        case .leftShoulder: "Press the left shoulder button"
        case .rightShoulder: "Press the right shoulder button"
        case .leftTrigger: "Pull the left trigger"
        case .rightTrigger: "Pull the right trigger"
        case .select: "Press Select"
        case .start: "Press Start"
        case .dpadUp: "Press up on the d-pad"
        case .leftStickUp: "Move the left stick up"
        case .rightStickUp: "Move the right stick up"
        }
    }
}

/// Which device a capture opens: by USB identity, or by the product name
/// GameController shows when the identity is not known.
public enum SupportTarget: Equatable, Hashable, Sendable {
    case usb(vendorId: UInt16, productId: UInt16)
    case named(String)

    static let namedPrefix = "named:"

    /// "057e:2019", or "named:<product>": the key a page is pushed with.
    public var deviceKey: String {
        switch self {
        case let .usb(vendorId, productId): usbPathKey(vendorId: vendorId, productId: productId)
        case let .named(name): Self.namedPrefix + name
        }
    }

    public init?(deviceKey: String) {
        if deviceKey.hasPrefix(Self.namedPrefix) {
            let name = String(deviceKey.dropFirst(Self.namedPrefix.count))
            guard !name.isEmpty else { return nil }
            self = .named(name)
            return
        }
        guard let ids = parseUsbKey(deviceKey) else { return nil }
        self = .usb(vendorId: ids.vendorId, productId: ids.productId)
    }
}

private func parseUsbKey(_ key: String) -> (vendorId: UInt16, productId: UInt16)? {
    let parts = key.split(separator: ":", omittingEmptySubsequences: false)
    let shaped = parts.count == 2 && parts.allSatisfy { $0.count == 4 }
    guard shaped, let vendorId = UInt16(parts[0], radix: 16), let productId = UInt16(parts[1], radix: 16) else { return nil }
    return (vendorId, productId)
}

/// What the capture read off the device as it opened it.
public struct SupportDevice: Equatable, Sendable {
    public let vendorId: UInt16
    public let productId: UInt16
    public let product: String
    public let manufacturer: String
    /// IOKit's transport word, "USB" or "Bluetooth".
    public let transport: String
    public let descriptor: [UInt8]

    public init(vendorId: UInt16, productId: UInt16, product: String, manufacturer: String, transport: String, descriptor: [UInt8]) {
        self.vendorId = vendorId
        self.productId = productId
        self.product = product
        self.manufacturer = manufacturer
        self.transport = transport
        self.descriptor = descriptor
    }

    public var hardwareKey: String {
        usbPathKey(vendorId: vendorId, productId: productId)
    }
}

public struct SupportStepRecord: Equatable, Sendable {
    public let step: SupportStep
    /// Nil when the step was skipped.
    public let reports: [[UInt8]]?

    public init(step: SupportStep, reports: [[UInt8]]?) {
        self.step = step
        self.reports = reports
    }
}

public enum SupportLimits {
    /// A stick swept through its travel sends hundreds of distinct reports;
    /// the first ones say enough.
    public static let reportsPerStep = 32
}

public enum SupportPhase: Equatable, Sendable {
    /// Waiting for the device to be found, or found again.
    case searching
    case stepping
    case finished
}

public struct SupportCaptureState: Equatable, Sendable {
    public var device: SupportDevice?
    public var stepIndex = 0
    /// The distinct reports of the step on screen, in arrival order.
    public var current: [[UInt8]] = []
    public var records: [SupportStepRecord] = []

    public init() {}

    public var step: SupportStep? {
        stepIndex < SupportStep.allCases.count ? SupportStep.allCases[stepIndex] : nil
    }

    public var phase: SupportPhase {
        if step == nil { return .finished }
        return device == nil ? .searching : .stepping
    }
}

public enum SupportCaptureEvent: Equatable, Sendable {
    case deviceFound(SupportDevice)
    case deviceLost
    /// The reports the ring held, oldest first.
    case reports([[UInt8]])
    case next
    case skip
}

public func reduceSupportCapture(_ state: SupportCaptureState, _ event: SupportCaptureEvent) -> SupportCaptureState {
    var next = state
    switch event {
    case let .deviceFound(device): next.device = device
    case .deviceLost: next.device = nil
    case let .reports(reports): next.current = collected(state, reports)
    case .next: return finishedStep(state, reports: state.current)
    case .skip: return finishedStep(state, reports: nil)
    }
    return next
}

/// Reports only count while a step is on screen and the device is open.
private func collected(_ state: SupportCaptureState, _ reports: [[UInt8]]) -> [[UInt8]] {
    guard state.phase == .stepping else { return state.current }
    var kept = state.current
    for report in reports where kept.count < SupportLimits.reportsPerStep && !kept.contains(report) {
        kept.append(report)
    }
    return kept
}

/// Only a step on screen with its device open moves on.
private func finishedStep(_ state: SupportCaptureState, reports: [[UInt8]]?) -> SupportCaptureState {
    guard state.phase == .stepping, let step = state.step else { return state }
    var next = state
    next.records.append(SupportStepRecord(step: step, reports: reports))
    next.current = []
    next.stepIndex += 1
    return next
}

// MARK: - The report

/// Lowercase hex pairs, space-separated.
public func hexBytes(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
}

public enum SupportReportLayout {
    static let descriptorBytesPerLine = 16
    static let indent = "  "
    public static let issuesURL = "https://github.com/TinkerNorth/dish-mac/issues/new"
}

/// The device's facts, its descriptor in rows of 16 bytes, and each step's
/// reports, as plain text to paste into an issue.
public func supportReportText(_ state: SupportCaptureState) -> String {
    guard let device = state.device else { return "" }
    let header = [
        "Controller support capture (Dish for macOS)",
        "Product: \(device.product)",
        "Manufacturer: \(device.manufacturer)",
        "VID:PID: \(device.hardwareKey)",
        "Transport: \(device.transport)",
        "",
        "HID report descriptor (\(device.descriptor.count) bytes):"
    ]
    let descriptor = descriptorRows(device.descriptor).map { SupportReportLayout.indent + $0 }
    let steps = state.records.flatMap(stepLines)
    return (header + descriptor + ["", "Input reports per step:"] + steps).joined(separator: "\n")
}

private func descriptorRows(_ bytes: [UInt8]) -> [String] {
    stride(from: 0, to: bytes.count, by: SupportReportLayout.descriptorBytesPerLine).map { start in
        let end = min(start + SupportReportLayout.descriptorBytesPerLine, bytes.count)
        return hexBytes(Array(bytes[start ..< end]))
    }
}

private func stepLines(_ record: SupportStepRecord) -> [String] {
    guard let reports = record.reports else { return ["\(record.step.reportName): skipped"] }
    guard !reports.isEmpty else { return ["\(record.step.reportName): no reports"] }
    return ["\(record.step.reportName):"] + reports.map { SupportReportLayout.indent + hexBytes($0) }
}

/// "Controller support: <product> (<vid:pid>)", the issue's title.
public func supportIssueTitle(_ device: SupportDevice) -> String {
    let name = device.product.isEmpty ? device.hardwareKey : device.product
    return "Controller support: \(name) (\(device.hardwareKey))"
}

/// A new issue on dish-mac with the title filled in; the user pastes the
/// copied report as its body.
public func supportIssueURL(_ device: SupportDevice) -> URL? {
    let title = supportIssueTitle(device).addingPercentEncoding(withAllowedCharacters: urlUnreserved)
    var components = URLComponents(string: SupportReportLayout.issuesURL)
    components?.percentEncodedQueryItems = [URLQueryItem(name: "title", value: title)]
    return components?.url
}

/// RFC 3986's unreserved characters, ASCII only: everything else in a
/// title (a space, "&", "+", a letter outside ASCII) is percent-encoded.
private let urlUnreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
