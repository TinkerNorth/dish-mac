// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// `dish-diagnostics.v1` (dish-website `docs/diagnostics-bundle.md`): one JSON
// file, the same shape from every client, built here from facts the pages
// already render and nothing else. Hosts are "Host 1", "Host 2"; their
// names and addresses are replaced wherever a log line carries them. The
// bundle never holds pairing keys, secrets, fingerprints, addresses, Wi-Fi
// names or the names of hosts, and nothing from the microphone or speaker.

import Foundation

// MARK: - What the builder reads

public struct BundleAppFacts: Equatable, Sendable {
    public let name: String
    public let version: String
    public let build: String
    public let flavor: String

    public init(name: String, version: String, build: String, flavor: String) {
        self.name = name
        self.version = version
        self.build = build
        self.flavor = flavor
    }
}

public struct BundleDeviceFacts: Equatable, Sendable {
    public let model: String
    public let os: String
    public let arch: String

    public init(model: String, os: String, arch: String) {
        self.model = model
        self.os = os
        self.arch = arch
    }
}

public struct BundleHardwareFacts: Equatable, Sendable {
    public let vendorId: UInt16
    public let productId: UInt16
    public let product: String?
    public let manufacturer: String?

    public init(vendorId: UInt16, productId: UInt16, product: String?, manufacturer: String?) {
        self.vendorId = vendorId
        self.productId = productId
        self.product = product
        self.manufacturer = manufacturer
    }
}

/// How the Mac reads a pad.
public enum BundlePadPath: String, Equatable, Sendable {
    case direct
    case gameController
}

public struct BundlePadFacts: Equatable, Sendable {
    public let record: ControllerRecord?
    public let transport: ControllerTransport?
    public let path: BundlePadPath
    public let hardware: BundleHardwareFacts?
    public let expectMismatches: [String]
    public let lastWrite: DirectWriteVerdict?
    public let outcomes: [TestOutcome]
    /// The support capture's text, for the one pad the person captured.
    public let capture: String?

    public init(
        record: ControllerRecord?,
        transport: ControllerTransport?,
        path: BundlePadPath,
        hardware: BundleHardwareFacts?,
        expectMismatches: [String] = [],
        lastWrite: DirectWriteVerdict? = nil,
        outcomes: [TestOutcome] = [],
        capture: String? = nil
    ) {
        self.record = record
        self.transport = transport
        self.path = path
        self.hardware = hardware
        self.expectMismatches = expectMismatches
        self.lastWrite = lastWrite
        self.outcomes = outcomes
        self.capture = capture
    }
}

public enum BundleHostKind: String, Equatable, Sendable {
    case satellite
    case moonlight
}

public struct BundleHostFacts: Equatable, Sendable {
    /// What the person and the network call it: only ever replaced.
    public let names: [String]
    public let kind: BundleHostKind
    public let version: String?
    public let protocolVersion: Int?
    public let link: String
    public let grants: HostAudioVerdict?

    public init(names: [String], kind: BundleHostKind, version: String?, protocolVersion: Int?, link: String, grants: HostAudioVerdict?) {
        self.names = names
        self.kind = kind
        self.version = version
        self.protocolVersion = protocolVersion
        self.link = link
        self.grants = grants
    }
}

public struct BundleLogFacts: Equatable, Sendable {
    public let atMs: Int64
    public let tag: String
    public let message: String

    public init(atMs: Int64, tag: String, message: String) {
        self.atMs = atMs
        self.tag = tag
        self.message = message
    }
}

public struct DiagnosticsBundleFacts: Equatable, Sendable {
    public let createdAtMs: Int64
    public let app: BundleAppFacts
    public let device: BundleDeviceFacts
    public let controllerDb: ControllerDbStatus
    public let pads: [BundlePadFacts]
    public let hosts: [BundleHostFacts]
    public let log: [BundleLogFacts]

    public init(
        createdAtMs: Int64,
        app: BundleAppFacts,
        device: BundleDeviceFacts,
        controllerDb: ControllerDbStatus,
        pads: [BundlePadFacts],
        hosts: [BundleHostFacts],
        log: [BundleLogFacts]
    ) {
        self.createdAtMs = createdAtMs
        self.app = app
        self.device = device
        self.controllerDb = controllerDb
        self.pads = pads
        self.hosts = hosts
        self.log = log
    }
}

// MARK: - The file

public enum DiagnosticsBundleFormat {
    public static let version = 1
    public static let recipient = "support@tinkernorth.com"
}

/// "Host 1" for the first host, and so on.
public func hostAlias(_ position: Int) -> String {
    "Host \(position + 1)"
}

/// The file's bytes: sorted keys, so two bundles of one state are equal.
public func diagnosticsBundleJSON(_ facts: DiagnosticsBundleFacts) -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return (try? encoder.encode(diagnosticsBundle(facts))) ?? Data()
}

/// The file's shape, every host aliased and every log line scrubbed of the
/// names and addresses those hosts go by.
func diagnosticsBundle(_ facts: DiagnosticsBundleFacts) -> BundleFile {
    let aliases = hostAliases(facts.hosts)
    return BundleFile(
        bundle: DiagnosticsBundleFormat.version,
        createdAt: isoTimestamp(facts.createdAtMs),
        app: BundleFile.App(name: facts.app.name, version: facts.app.version, build: facts.app.build, flavor: facts.app.flavor),
        device: BundleFile.Device(model: facts.device.model, os: facts.device.os, arch: facts.device.arch),
        controllerDb: bundleControllerDb(facts.controllerDb),
        controllers: facts.pads.map(bundleController),
        hosts: facts.hosts.enumerated().map { bundleHost($1, alias: hostAlias($0)) },
        log: facts.log.map { BundleFile.Log(atMs: $0.atMs, tag: $0.tag, message: scrub($0.message, aliases)) }
    )
}

private struct HostAliasing {
    let name: String
    let alias: String
}

/// Longest first, so a name that contains another is replaced whole.
private func hostAliases(_ hosts: [BundleHostFacts]) -> [HostAliasing] {
    let pairs = hosts.enumerated().flatMap { position, host in
        host.names.filter { !$0.isEmpty }.map { HostAliasing(name: $0, alias: hostAlias(position)) }
    }
    return pairs.sorted { $0.name.count > $1.name.count }
}

private func scrub(_ text: String, _ aliases: [HostAliasing]) -> String {
    aliases.reduce(text) { scrubbed, aliasing in scrubbed.replacingOccurrences(of: aliasing.name, with: aliasing.alias) }
}

private func bundleControllerDb(_ status: ControllerDbStatus) -> BundleFile.ControllerDb {
    BundleFile.ControllerDb(
        bundledVersion: status.bundledVersion,
        activeVersion: status.activeVersion,
        source: status.source.rawValue,
        lastCheckAt: status.lastCheckAtMs.map(isoTimestamp),
        lastCheckResult: status.lastCheckResult?.rawValue
    )
}

private func bundleController(_ pad: BundlePadFacts) -> BundleFile.Controller {
    BundleFile.Controller(
        record: pad.record?.id,
        verification: pad.record?.verification.rawValue,
        transport: pad.transport?.rawValue,
        path: pad.path.rawValue,
        hardware: pad.hardware.map(bundleHardware),
        expectMismatch: pad.expectMismatches,
        lastFeedback: nil,
        lastWrite: pad.lastWrite.map(bundleWrite),
        outcomes: pad.outcomes.map { BundleFile.Outcome(test: $0.test.rawValue, result: $0.result.rawValue, atMs: $0.atMs) },
        capture: pad.capture.map { BundleFile.Capture(format: BundleFile.Capture.supportCaptureText, text: $0) }
    )
}

private func bundleHardware(_ hardware: BundleHardwareFacts) -> BundleFile.Hardware {
    BundleFile.Hardware(
        vid: String(format: "%04x", UInt32(hardware.vendorId)),
        pid: String(format: "%04x", UInt32(hardware.productId)),
        product: hardware.product,
        manufacturer: hardware.manufacturer
    )
}

private func bundleWrite(_ write: DirectWriteVerdict) -> BundleFile.Write {
    BundleFile.Write(
        route: write.route.rawValue,
        reportId: String(format: "%02x", UInt32(write.reportId)),
        ok: write.ok,
        err: write.error,
        atMs: write.atMs
    )
}

private func bundleHost(_ host: BundleHostFacts, alias: String) -> BundleFile.Host {
    BundleFile.Host(
        alias: alias,
        kind: host.kind.rawValue,
        version: host.version,
        protocolVersion: host.protocolVersion,
        link: host.link,
        grants: host.grants.map { BundleFile.Grants(mic: $0.mic, speaker: $0.speaker, hapticAudio: $0.hapticAudio) }
    )
}

/// "2026-11-19T21:04:11Z".
public func isoTimestamp(_ ms: Int64) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    formatter.timeZone = TimeZone(identifier: "UTC")
    return formatter.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
}

/// The attachment's name: `dish-diagnostics-<app>-<yyyyMMdd-HHmmss>.json`,
/// in UTC so two machines name the same moment alike.
public func diagnosticsBundleFileName(app: String, atMs: Int64) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    let stamp = formatter.string(from: Date(timeIntervalSince1970: Double(atMs) / 1000))
    return "dish-diagnostics-\(app)-\(stamp).json"
}

// MARK: - The encoded shape

struct BundleFile: Encodable {
    struct App: Encodable {
        let name: String
        let version: String
        let build: String
        let flavor: String
    }

    struct Device: Encodable {
        let model: String
        let os: String
        let arch: String
    }

    struct ControllerDb: Encodable {
        let bundledVersion: Int
        let activeVersion: Int
        let source: String
        let lastCheckAt: String?
        let lastCheckResult: String?
    }

    struct Hardware: Encodable {
        let vid: String
        let pid: String
        let product: String?
        let manufacturer: String?
    }

    struct Write: Encodable {
        let route: String
        let reportId: String
        let ok: Bool
        let err: String?
        let atMs: Int64
    }

    struct Outcome: Encodable {
        let test: String
        let result: String
        let atMs: Int64
    }

    /// The contract's capture object; the Mac's format is its Help-support text.
    struct Capture: Encodable {
        static let supportCaptureText = "support-capture-text"

        let format: String
        let text: String
    }

    struct Feedback: Encodable {
        let kind: String
        let atMs: Int64
        let count: Int
    }

    struct Controller: Encodable {
        let record: String?
        let verification: String?
        let transport: String?
        let path: String
        let hardware: Hardware?
        let expectMismatch: [String]
        let lastFeedback: Feedback?
        let lastWrite: Write?
        let outcomes: [Outcome]
        let capture: Capture?

        private enum CodingKeys: String, CodingKey {
            case record, verification, transport, path, hardware, expectMismatch, lastFeedback, lastWrite, outcomes, capture
        }

        /// `record` and `capture` are written as null when there is none, as
        /// the contract shows them.
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(record, forKey: .record)
            try container.encodeIfPresent(verification, forKey: .verification)
            try container.encodeIfPresent(transport, forKey: .transport)
            try container.encode(path, forKey: .path)
            try container.encodeIfPresent(hardware, forKey: .hardware)
            try container.encode(expectMismatch, forKey: .expectMismatch)
            try container.encodeIfPresent(lastFeedback, forKey: .lastFeedback)
            try container.encodeIfPresent(lastWrite, forKey: .lastWrite)
            try container.encode(outcomes, forKey: .outcomes)
            try container.encode(capture, forKey: .capture)
        }
    }

    struct Grants: Encodable {
        let mic: Bool
        let speaker: Bool
        let hapticAudio: Bool
    }

    struct Host: Encodable {
        let alias: String
        let kind: String
        let version: String?
        let protocolVersion: Int?
        let link: String
        let grants: Grants?

        private enum CodingKeys: String, CodingKey {
            case alias, kind, version, protocolVersion = "protocol", link, grants
        }
    }

    struct Log: Encodable {
        let atMs: Int64
        let tag: String
        let message: String
    }

    let bundle: Int
    let createdAt: String
    let app: App
    let device: Device
    let controllerDb: ControllerDb
    let controllers: [Controller]
    let hosts: [Host]
    let log: [Log]
}
