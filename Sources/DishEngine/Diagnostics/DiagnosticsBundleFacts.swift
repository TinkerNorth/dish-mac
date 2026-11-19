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

package func diagnosticsBundleFacts(_ inputs: DiagnosticsBundleInputs) -> DiagnosticsBundleFacts {
    let hosts = inputs.snapshot.hosts.map { bundleHostFacts($0, versions: inputs.hostVersions) }
    let known = Set(hosts.flatMap(\.names))
    return DiagnosticsBundleFacts(
        createdAtMs: inputs.createdAtMs,
        app: inputs.app,
        device: BundleDeviceFacts(model: inputs.machine.model, os: inputs.machine.osName, arch: inputs.machine.arch),
        controllerDb: inputs.snapshot.controllerDb,
        pads: inputs.snapshot.pads.map { bundlePadFacts($0, outcomes: inputs.outcomes, capture: inputs.capture) },
        hosts: hosts,
        log: inputs.events.map { bundleLogLine($0, knownHosts: known) }
    )
}

/// The name, the address and what a Moonlight host calls itself: each is
/// only ever replaced by the host's alias.
func bundleHostFacts(_ host: HostDiagnostics, versions: [String: String]) -> BundleHostFacts {
    let summary = host.summary
    let names = [summary.name, summary.address, summary.recordName, host.moonlight?.info?.hostname ?? ""]
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
    let hardware = pad.hardwareId.map { id in
        BundleHardwareFacts(
            vendorId: UInt16(clamping: id.vendorId),
            productId: UInt16(clamping: id.productId),
            product: pad.device.map(\.name) ?? pad.slot.name,
            manufacturer: pad.device.flatMap { $0.manufacturer.isEmpty ? nil : $0.manufacturer }
        )
    }
    let direct = pad.inputPath?.source == .direct
    return BundlePadFacts(
        record: pad.record,
        transport: pad.transport,
        path: direct ? .direct : .gameController,
        hardware: hardware,
        expectMismatches: pad.inputPath?.expectMismatches ?? [],
        lastWrite: pad.inputPath?.lastWrite,
        outcomes: outcomes.answers[pad.slot.id] ?? [],
        capture: capture.flatMap { captured(pad, by: $0) ? $0.report : nil }
    )
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
