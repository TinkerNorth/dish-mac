// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// The diagnostics bundle's facts, gathered from what the Diagnostics page
// already renders: the snapshot, the flight recorder, the answers and the
// last support capture. A pure fold; the core's builder makes the file. A
// host is handed over with every name it goes by, so the builder can alias
// it wherever a log line says it, and a log line naming a host that is no
// longer listed says "another host" instead.

import DishCore
import Foundation

/// Everything the bundle reads, taken on the main actor at the press.
package struct DiagnosticsBundleInputs {
    package let createdAtMs: Int64
    package let app: BundleAppFacts
    package let machine: HostMachine
    package let snapshot: DiagnosticsSnapshot
    package let events: [DiagnosticsEvent]
    package let outcomes: PadOutcomes
    package let capture: FinishedCapture?
    /// What each satellite said of its own version, by connection id.
    package let hostVersions: [String: String]
    /// The client's own view of each live satellite session, by connection id.
    package var sessions: [String: BundleSessionFacts] = [:]
    /// What each satellite's probe and catalog said, by connection id.
    package var capabilities: [String: SatelliteCapabilitiesFacts] = [:]
    /// Each pad's feed and feedback, by slot id.
    package var padReadings: [String: PadPathReading] = [:]
    /// The person's report; nil for Save diagnostics.
    package var report: SupportReportDraft?
    /// What preparing the report gathered; nil when nothing was asked.
    package var preparation: ReportPreparation?

    package init(
        createdAtMs: Int64,
        app: BundleAppFacts,
        machine: HostMachine,
        snapshot: DiagnosticsSnapshot,
        events: [DiagnosticsEvent],
        outcomes: PadOutcomes,
        capture: FinishedCapture?,
        hostVersions: [String: String]
    ) {
        self.createdAtMs = createdAtMs
        self.app = app
        self.machine = machine
        self.snapshot = snapshot
        self.events = events
        self.outcomes = outcomes
        self.capture = capture
        self.hostVersions = hostVersions
    }
}

let unlistedHostWord = "another host"

/// With a report, the support capture rides only the pad the report names.
package func diagnosticsBundleFacts(_ inputs: DiagnosticsBundleInputs) -> DiagnosticsBundleFacts {
    let pads = inputs.snapshot.pads
    let records = padRecords(pads)
    let hosts = inputs.snapshot.hosts.map { host in
        bundleHostFacts(host, versions: inputs.hostVersions)
            .with(session: hostSession(host, inputs: inputs, records: records), snapshot: hostSnapshot(host, inputs: inputs))
    }
    let known = Set(hosts.flatMap(\.names))
    let padFacts = pads.map { pad in
        bundlePadFacts(pad, outcomes: inputs.outcomes, capture: captureRiding(pad, inputs: inputs))
            .with(reading: inputs.padReadings[pad.slot.id], pad: pad)
    }
    return DiagnosticsBundleFacts(
        createdAtMs: inputs.createdAtMs,
        app: inputs.app,
        device: BundleDeviceFacts(model: inputs.machine.model, os: inputs.machine.osName, arch: inputs.machine.arch),
        controllerDb: inputs.snapshot.controllerDb,
        pads: padFacts,
        hosts: hosts,
        log: inputs.events.map { bundleLogLine($0, knownHosts: known) },
        report: inputs.report.map { supportReport($0, pads: pads) },
        conditions: inputs.preparation?.conditions
    )
}

private func captureRiding(_ pad: PadDiagnostics, inputs: DiagnosticsBundleInputs) -> FinishedCapture? {
    guard let report = inputs.report else { return inputs.capture }
    return report.slotId == pad.slot.id ? inputs.capture : nil
}

/// A satellite's session as the client counts it; a Moonlight host's pads
/// and its control round trip.
private func hostSession(_ host: HostDiagnostics, inputs: DiagnosticsBundleInputs, records: [String: String]) -> BundleSessionFacts? {
    switch host.summary.kind {
    case .moonlight: host.moonlight.flatMap { moonlightSession($0, records: records) }
    case .satellite, .bluetooth: inputs.sessions[host.id]
    }
}

/// Nil while the host carries no pad and measured no round trip.
func moonlightSession(_ moonlight: MoonlightHostDiagnostics, records: [String: String]) -> BundleSessionFacts? {
    let rtt = moonlight.controlRoundTripMs.map(Double.init)
    guard !moonlight.pads.isEmpty || rtt != nil else { return nil }
    let slots = moonlight.pads.map { pad in
        BundleSessionSlot(
            index: Int(pad.number),
            record: records[pad.slotId],
            requestedType: String(pad.type),
            appliedType: nil,
            backend: nil,
            result: nil,
            touchpadMode: nil
        )
    }
    let latency = LatencySummary(p50RttMs: rtt, p99RttMs: nil, samples: rtt == nil ? 0 : 1, capacity: 1)
    return BundleSessionFacts(slots: slots, ack: nil, latency: latency, counts: nil)
}

/// Nil when no report was prepared: Save diagnostics asks nobody.
private func hostSnapshot(_ host: HostDiagnostics, inputs: DiagnosticsBundleInputs) -> BundleHostSnapshot? {
    guard let preparation = inputs.preparation else { return nil }
    switch host.summary.kind {
    case .moonlight: return moonlightHostSnapshot(host.moonlight?.info)
    case .satellite, .bluetooth: return satelliteHostSnapshot(preparation.snapshots[host.id], fallback: inputs.capabilities[host.id])
    }
}

extension BundleHostFacts {
    func with(session: BundleSessionFacts?, snapshot: BundleHostSnapshot?) -> BundleHostFacts {
        BundleHostFacts(
            names: names,
            kind: kind,
            version: version,
            protocolVersion: protocolVersion,
            link: link,
            grants: grants,
            session: session,
            snapshot: snapshot
        )
    }
}

extension BundlePadFacts {
    /// The pad's input and output beside the first cut's facts.
    func with(reading: PadPathReading?, pad: PadDiagnostics) -> BundlePadFacts {
        BundlePadFacts(
            record: record,
            transport: transport,
            bluetoothLayer: bluetoothLayer,
            path: path,
            hardware: hardware,
            expectMismatches: expectMismatches,
            lastWrite: lastWrite,
            outcomes: outcomes,
            capture: capture,
            input: reading.flatMap(bundlePadInput),
            output: bundlePadOutput(pad, counts: reading?.output ?? PadOutputCounts()),
            audio: audio
        )
    }
}

/// The name, the address and what a Moonlight host calls itself: each is
/// only ever replaced by the host's alias, in the file and in the mail.
package func diagnosticsHostNames(_ host: HostDiagnostics) -> [String] {
    let summary = host.summary
    return [summary.name, summary.address, summary.recordName, host.moonlight?.info?.hostname ?? ""]
}

func bundleHostFacts(_ host: HostDiagnostics, versions: [String: String]) -> BundleHostFacts {
    let summary = host.summary
    let names = diagnosticsHostNames(host)
    switch summary.kind {
    case .moonlight:
        return BundleHostFacts(
            names: names,
            kind: .moonlight,
            version: host.moonlight?.info?.appVersion,
            protocolVersion: nil,
            link: linkWord(summary.live),
            grants: nil
        )
    case .satellite, .bluetooth:
        return BundleHostFacts(
            names: names,
            kind: .satellite,
            version: versions[summary.id].flatMap { $0.isEmpty ? nil : $0 },
            protocolVersion: host.facts.live ? host.facts.settledProtocol : nil,
            link: linkWord(summary.live),
            grants: host.facts.audio
        )
    }
}

func linkWord(_ state: LinkState) -> String {
    switch state {
    case .found: "found"
    case .stale: "stale"
    case .saved: "saved"
    case .ready: "ready"
    case .connecting: "connecting"
    case .connected: "connected"
    case .unstable: "unstable"
    }
}

func bundlePadFacts(_ pad: PadDiagnostics, outcomes: PadOutcomes, capture: FinishedCapture?) -> BundlePadFacts {
    let hardware = pad.hardwareId.map { bundleHardwareFacts($0, pad: pad) }
    let direct = pad.inputPath?.source == .direct
    return BundlePadFacts(
        record: pad.record,
        transport: pad.transport,
        bluetoothLayer: bluetoothLayer(of: pad.hidTransport),
        path: direct ? .direct : .gameController,
        hardware: hardware,
        expectMismatches: pad.inputPath?.expectMismatches ?? [],
        lastWrite: pad.inputPath?.lastWrite,
        outcomes: outcomes.answers(pad.slot.id),
        capture: capture.flatMap { captured(pad, by: $0) ? capturedWithDescriptors($0, pad: pad) : nil },
        audio: bundleAudio(pad.audio)
    )
}

/// The capture with the configuration descriptors of the pad's USB device,
/// never its device descriptor, which the Mac rebuilds: the capture
/// itself reads the HID side only.
func capturedWithDescriptors(_ capture: FinishedCapture, pad: PadDiagnostics) -> BundleCapture? {
    capture.capture?.with(usbDevice: nil, configurations: pad.usbDescriptors?.configurations)
}

/// The pad's ids, names and what IOKit said of its hardware.
func bundleHardwareFacts(_ id: HidHardwareId, pad: PadDiagnostics) -> BundleHardwareFacts {
    let detail = pad.hardwareDetail
    var hardware = BundleHardwareFacts(
        vendorId: UInt16(clamping: id.vendorId),
        productId: UInt16(clamping: id.productId),
        product: pad.device.map(\.name) ?? pad.slot.name,
        manufacturer: pad.device.flatMap { $0.manufacturer.isEmpty ? nil : $0.manufacturer }
    )
    hardware.bcdDevice = detail?.versionNumber.map { UInt16(clamping: $0) }
    hardware.interfaces = detail?.interfaces
    hardware.endpoints = detail?.endpoints
    hardware.descriptorSha256 = detail?.descriptorSha256
    return hardware
}

/// The pad's own USB audio function as Core Audio lists it: its playback
/// channels, and whether macOS refused either endpoint. Nil while no
/// function is routed to the pad.
func bundleAudio(_ audio: PadAudioDiagnostics?) -> BundleAudio? {
    guard let function = audio?.route?.function else { return nil }
    let playbackRefused = audio?.state?.playbackRefused ?? false
    let captureRefused = audio?.state?.captureRefused ?? false
    return BundleAudio(channels: function.device.outputChannels, refused: playbackRefused || captureRefused)
}

/// The link IOKit named for a Bluetooth pad; nil for any other transport.
func bluetoothLayer(of transport: HidTransport?) -> BluetoothTransportLayer? {
    guard case let .bluetooth(layer) = transport else { return nil }
    return layer
}

/// The capture belongs to the pad its key names: by USB identity, or by the
/// product name GameController shows.
func captured(_ pad: PadDiagnostics, by capture: FinishedCapture) -> Bool {
    let byIdentity = pad.hardwareId.map { id in
        capture.deviceKey == usbPathKey(vendorId: UInt16(clamping: id.vendorId), productId: UInt16(clamping: id.productId))
    } ?? false
    return byIdentity || capture.deviceKey == "named:\(pad.slot.name)"
}

/// The line's kind and what it says, with no words of the app's.
func bundleLogLine(_ event: DiagnosticsEvent, knownHosts: Set<String>) -> BundleLogFacts {
    let tag = String(describing: event.kind)
    let message: String = switch event.kind {
    case .linkAppeared, .linkRemoved:
        "\(listedHost(event.subject, knownHosts)): \(linkWord(event.to))"
    case .linkChanged:
        "\(listedHost(event.subject, knownHosts)): \(linkWord(event.from)) -> \(linkWord(event.to))"
    case .padAttached:
        event.subject
    case .padDetached, .padBound, .padUnbound:
        event.host.isEmpty ? event.subject : "\(event.subject) -> \(listedHost(event.host, knownHosts))"
    case .padPathChosen, .padCheckConcluded, .padKeepsDisconnecting:
        "\(event.subject): \(event.path.map { String(describing: $0) } ?? tag)"
    }
    return BundleLogFacts(atMs: event.atMs, tag: tag, message: message)
}

private func listedHost(_ name: String, _ known: Set<String>) -> String {
    known.contains(name) ? name : unlistedHostWord
}

/// Each pad's record id, by slot id; a pad no record matched is left out.
func padRecords(_ pads: [PadDiagnostics]) -> [String: String] {
    Dictionary(uniqueKeysWithValues: pads.compactMap { pad in pad.record.map { (pad.slot.id, $0.id) } })
}
