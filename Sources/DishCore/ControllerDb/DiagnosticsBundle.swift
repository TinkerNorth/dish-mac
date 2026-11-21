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

/// One interface of a pad's USB device, as the IORegistry lists it.
public struct BundleUsbInterface: Equatable, Sendable {
    public let number: Int
    public let interfaceClass: UInt8
    public let subclass: UInt8
    public let interfaceProtocol: UInt8

    public init(number: Int, interfaceClass: UInt8, subclass: UInt8, interfaceProtocol: UInt8) {
        self.number = number
        self.interfaceClass = interfaceClass
        self.subclass = subclass
        self.interfaceProtocol = interfaceProtocol
    }
}

/// The addresses of the endpoints Dish opened itself; an OUT endpoint the
/// interface lacks is nil.
public struct BundleEndpoints: Equatable, Sendable {
    public let input: UInt8
    public let output: UInt8?

    public init(input: UInt8, output: UInt8?) {
        self.input = input
        self.output = output
    }
}

public struct BundleHardwareFacts: Equatable, Sendable {
    public let vendorId: UInt16
    public let productId: UInt16
    public let product: String?
    public let manufacturer: String?
    /// `kIOHIDVersionNumberKey`, a USB pad's `bcdDevice`; nil when IOKit gives none.
    public var bcdDevice: UInt16?
    /// The USB device's interfaces; nil off USB, or when the IORegistry has
    /// no USB device above the pad.
    public var interfaces: [BundleUsbInterface]?
    /// Nil where IOKit does not say: only a pad Dish opens itself names them.
    public var endpoints: BundleEndpoints?
    /// SHA-256 of the raw USB descriptors (the device descriptor, then each
    /// configuration descriptor in index order), lowercase hex; nil off USB
    /// and where IOKit hands none over.
    public var descriptorSha256: String?

    public init(vendorId: UInt16, productId: UInt16, product: String?, manufacturer: String?) {
        self.vendorId = vendorId
        self.productId = productId
        self.product = product
        self.manufacturer = manufacturer
    }
}

/// The pad's own USB audio function: the playback channels Core Audio
/// lists, and whether macOS refused an endpoint of it.
public struct BundleAudio: Equatable, Sendable {
    public let channels: Int
    public let refused: Bool

    public init(channels: Int, refused: Bool) {
        self.channels = channels
        self.refused = refused
    }
}

/// A Help-support capture in `usb-descriptors-v1`'s terms.
public struct BundleCapture: Equatable, Sendable {
    public let product: String?
    public let manufacturer: String?
    /// The HID interface the descriptor is the device's own for; nil where
    /// IOKit names none.
    public let interfaceNumber: Int?
    /// `kIOHIDReportDescriptorKey`: the operating system's copy.
    public let reportDescriptor: [UInt8]
    public let restReports: [RestReport]
    /// The guided capture as the Mac formats it for an issue; nil when none
    /// ran.
    public let guided: String?
    /// The 18-byte device descriptor; nil off USB and where IOKit hands none
    /// over.
    public let device: [UInt8]?
    /// Each configuration descriptor in index order, as the bus delivered
    /// them; nil off USB and where IOKit hands none over.
    public let configuration: [[UInt8]]?

    public init(
        product: String?,
        manufacturer: String?,
        interfaceNumber: Int?,
        reportDescriptor: [UInt8],
        restReports: [RestReport],
        guided: String?,
        device: [UInt8]? = nil,
        configuration: [[UInt8]]? = nil
    ) {
        self.product = product
        self.manufacturer = manufacturer
        self.interfaceNumber = interfaceNumber
        self.reportDescriptor = reportDescriptor
        self.restReports = restReports
        self.guided = guided
        self.device = device
        self.configuration = configuration
    }

    /// The capture with its pad's USB device and configuration descriptors.
    public func with(usbDevice descriptor: [UInt8]?, configurations: [[UInt8]]?) -> BundleCapture {
        BundleCapture(
            product: product,
            manufacturer: manufacturer,
            interfaceNumber: interfaceNumber,
            reportDescriptor: reportDescriptor,
            restReports: restReports,
            guided: guided,
            device: descriptor,
            configuration: configurations
        )
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
    /// The Bluetooth link IOKit named; nil off Bluetooth or when it named none.
    public let bluetoothLayer: BluetoothTransportLayer?
    public let path: BundlePadPath
    public let hardware: BundleHardwareFacts?
    public let expectMismatches: [String]
    public let lastWrite: DirectWriteVerdict?
    public let outcomes: [TestOutcome]
    /// The support capture, for the one pad the person captured.
    public let capture: BundleCapture?
    /// What went in; nil where the pad has no feed yet.
    public let input: BundlePadInput?
    /// What came out, lane by lane.
    public let output: BundlePadOutput?
    /// Nil while no audio function is routed to the pad.
    public let audio: BundleAudio?

    public init(
        record: ControllerRecord?,
        transport: ControllerTransport?,
        bluetoothLayer: BluetoothTransportLayer? = nil,
        path: BundlePadPath,
        hardware: BundleHardwareFacts?,
        expectMismatches: [String] = [],
        lastWrite: DirectWriteVerdict? = nil,
        outcomes: [TestOutcome] = [],
        capture: BundleCapture? = nil,
        input: BundlePadInput? = nil,
        output: BundlePadOutput? = nil,
        audio: BundleAudio? = nil
    ) {
        self.record = record
        self.transport = transport
        self.bluetoothLayer = bluetoothLayer
        self.path = path
        self.hardware = hardware
        self.expectMismatches = expectMismatches
        self.lastWrite = lastWrite
        self.outcomes = outcomes
        self.capture = capture
        self.input = input
        self.output = output
        self.audio = audio
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
                wifi: read.wifi.map { WifiFile(band: $0.band, rssiDbm: $0.rssiDbm, linkSpeedMbps: $0.linkSpeedMbps) },
                usbHost: read.usbHost
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
        rateHz: pad.input?.rateHz,
        audio: pad.audio.map { BundleFile.Audio(channels: $0.channels, refused: $0.refused) },
        lastFeedback: nil,
        lastWrite: write,
        outcomes: pad.outcomes.map { BundleFile.Outcome(test: $0.test.rawValue, result: $0.result.rawValue, atMs: $0.atMs) },
        capture: pad.capture.map(bundleCaptureFile),
        input: pad.input.map(bundleInput),
        output: pad.output.map { bundleOutput($0, write: write) },
        bluetooth: bundleBluetooth(pad.transport, layer: pad.bluetoothLayer).map(bundleBluetoothFile)
    )
}

private func bundleCaptureFile(_ capture: BundleCapture) -> BundleFile.Capture {
    let descriptor = BundleFile.ReportDescriptor(
        interface: capture.interfaceNumber,
        hex: contiguousHex(capture.reportDescriptor),
        source: BundleFile.ReportDescriptor.fromTheOperatingSystem
    )
    return BundleFile.Capture(
        device: capture.device.map(contiguousHex),
        configuration: capture.configuration.map { contiguousHex(Array($0.joined())) },
        strings: BundleFile.Strings(manufacturer: capture.manufacturer, product: capture.product),
        guided: capture.guided.map(BundleFile.Guided.init),
        hidReportDescriptors: capture.reportDescriptor.isEmpty ? [] : [descriptor],
        restReports: capture.restReports.map { BundleFile.Report(atMs: $0.atMs, hex: contiguousHex($0.bytes)) }
    )
}

/// "05010905": lowercase pairs with no separator, as dish-android writes them.
private func contiguousHex(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02x", $0) }.joined()
}

private func bundleHardware(_ hardware: BundleHardwareFacts) -> BundleFile.Hardware {
    BundleFile.Hardware(
        vid: hexWord(hardware.vendorId),
        pid: hexWord(hardware.productId),
        bcdDevice: hardware.bcdDevice.map(hexWord),
        product: hardware.product,
        manufacturer: hardware.manufacturer,
        interfaces: hardware.interfaces?.map(bundleInterface),
        endpoints: hardware.endpoints.map { BundleFile.Endpoints(input: hexByte($0.input), output: $0.output.map(hexByte)) },
        descriptorSha256: hardware.descriptorSha256
    )
}

private func bundleInterface(_ interface: BundleUsbInterface) -> BundleFile.Interface {
    BundleFile.Interface(
        number: interface.number,
        interfaceClass: hexByte(interface.interfaceClass),
        subclass: hexByte(interface.subclass),
        interfaceProtocol: hexByte(interface.interfaceProtocol)
    )
}

/// "0ce6": a USB id or release, four lowercase hex digits.
private func hexWord(_ value: UInt16) -> String {
    String(format: "%04x", UInt32(value))
}

/// "84": a class code or an endpoint address, two lowercase hex digits.
private func hexByte(_ value: UInt8) -> String {
    String(format: "%02x", UInt32(value))
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
