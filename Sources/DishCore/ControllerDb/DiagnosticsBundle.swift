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
    /// What went in; nil where the pad has no feed yet.
    public let input: BundlePadInput?
    /// What came out, lane by lane.
    public let output: BundlePadOutput?

    public init(
        record: ControllerRecord?,
        transport: ControllerTransport?,
        path: BundlePadPath,
        hardware: BundleHardwareFacts?,
        expectMismatches: [String] = [],
        lastWrite: DirectWriteVerdict? = nil,
        outcomes: [TestOutcome] = [],
        capture: String? = nil,
        input: BundlePadInput? = nil,
        output: BundlePadOutput? = nil
    ) {
        self.record = record
        self.transport = transport
        self.path = path
        self.hardware = hardware
        self.expectMismatches = expectMismatches
        self.lastWrite = lastWrite
        self.outcomes = outcomes
        self.capture = capture
        self.input = input
        self.output = output
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
    /// The client's own view of the session; nil while there is none.
    public let session: BundleSessionFacts?
    /// What the host said of itself; nil when the file was written without
    /// asking (Save diagnostics).
    public let snapshot: BundleHostSnapshot?

    public init(
        names: [String],
        kind: BundleHostKind,
        version: String?,
        protocolVersion: Int?,
        link: String,
        grants: HostAudioVerdict?,
        session: BundleSessionFacts? = nil,
        snapshot: BundleHostSnapshot? = nil
    ) {
        self.names = names
        self.kind = kind
        self.version = version
        self.protocolVersion = protocolVersion
        self.link = link
        self.grants = grants
        self.session = session
        self.snapshot = snapshot
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
    /// The person's own words, when the file goes with a report.
    public let report: SupportReport?
    /// Nil when the file was written without reading them.
    public let conditions: BundleDeviceConditions?

    public init(
        createdAtMs: Int64,
        app: BundleAppFacts,
        device: BundleDeviceFacts,
        controllerDb: ControllerDbStatus,
        pads: [BundlePadFacts],
        hosts: [BundleHostFacts],
        log: [BundleLogFacts],
        report: SupportReport? = nil,
        conditions: BundleDeviceConditions? = nil
    ) {
        self.createdAtMs = createdAtMs
        self.app = app
        self.device = device
        self.controllerDb = controllerDb
        self.pads = pads
        self.hosts = hosts
        self.log = log
        self.report = report
        self.conditions = conditions
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
        device: bundleDevice(facts.device, conditions: facts.conditions),
        controllerDb: bundleControllerDb(facts.controllerDb),
        controllers: facts.pads.map(bundleController),
        hosts: facts.hosts.enumerated().map { bundleHost($1, alias: hostAlias($0), aliases: aliases) },
        log: facts.log.map { BundleFile.Log(atMs: $0.atMs, tag: $0.tag, message: scrub($0.message, aliases)) },
        report: facts.report.map(supportReportFile)
    )
}

private func bundleDevice(_ device: BundleDeviceFacts, conditions: BundleDeviceConditions?) -> BundleFile.Device {
    BundleFile.Device(
        model: device.model,
        os: device.os,
        arch: device.arch,
        conditions: conditions.map { read in
            BundleFile.Conditions(
                battery: read.battery.map { BatteryFile(level: $0.level, charging: $0.charging) },
                thermal: read.thermal?.rawValue,
                powerSave: read.powerSave,
                wifi: read.wifi.map { WifiFile(band: $0.band, rssiDbm: $0.rssiDbm, linkSpeedMbps: $0.linkSpeedMbps) }
            )
        }
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
    let write = pad.lastWrite.map(bundleWrite)
    return BundleFile.Controller(
        record: pad.record?.id,
        verification: pad.record?.verification.rawValue,
        transport: pad.transport?.rawValue,
        path: pad.path.rawValue,
        hardware: pad.hardware.map(bundleHardware),
        expectMismatch: pad.expectMismatches,
        lastFeedback: nil,
        lastWrite: write,
        outcomes: pad.outcomes.map { BundleFile.Outcome(test: $0.test.rawValue, result: $0.result.rawValue, atMs: $0.atMs) },
        capture: pad.capture.map { BundleFile.Capture(format: BundleFile.Capture.supportCaptureText, text: $0) },
        input: pad.input.map(bundleInput),
        output: pad.output.map { bundleOutput($0, write: write) },
        bluetooth: bundleBluetooth(pad.transport).map(bundleBluetoothFile)
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

/// The host's own document is scrubbed like a log line: a host that names
/// itself, or another, is aliased here too.
private func bundleHost(_ host: BundleHostFacts, alias: String, aliases: [HostAliasing]) -> BundleFile.Host {
    BundleFile.Host(
        alias: alias,
        kind: host.kind.rawValue,
        version: host.version,
        protocolVersion: host.protocolVersion,
        link: host.link,
        grants: host.grants.map { BundleFile.Grants(mic: $0.mic, speaker: $0.speaker, hapticAudio: $0.hapticAudio) },
        session: host.session.map(bundleSession),
        snapshot: host.snapshot.map { taken in
            BundleFile.Snapshot(document: taken.snapshot?.mappingStrings { scrub($0, aliases) }, error: taken.error?.rawValue)
        }
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
