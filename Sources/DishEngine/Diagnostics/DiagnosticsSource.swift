// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import DishKernel
import Foundation

package struct HostDiagnostics: Equatable, Identifiable {
    package let summary: ConnectionSummary
    /// The satellite session; resting for a host of any other kind.
    package let facts: HostSessionFacts
    /// The Moonlight session; nil for a satellite.
    package let moonlight: MoonlightHostDiagnostics?

    package var id: String {
        summary.id
    }

    package init(summary: ConnectionSummary, facts: HostSessionFacts, moonlight: MoonlightHostDiagnostics? = nil) {
        self.summary = summary
        self.facts = facts
        self.moonlight = moonlight
    }
}

/// A pad's own audio as the pipeline sees it: its route, the engine's
/// plan and lamp once bound, and the lanes' counters.
package struct PadAudioDiagnostics: Equatable {
    package let route: PadAudioRoute?
    package let state: ControllerAudioState?
    package let counters: AudioCounters?

    package init(route: PadAudioRoute?, state: ControllerAudioState?, counters: AudioCounters?) {
        self.route = route
        self.state = state
        self.counters = counters
    }
}

package struct PadDiagnostics: Equatable, Identifiable {
    package let slot: ControllerSlot
    /// Nil for an unbound pad, or one whose connection carries no descriptor.
    package let wire: SlotWireFacts?
    /// Nil until the audio catalog has been read.
    package let audio: PadAudioDiagnostics?
    /// Whether the pad's input reaches Dish while another app is in front.
    package let backgroundInput: Bool
    /// The HID device under the pad: a Direct pad's own, else the one the
    /// census finds by its name, when exactly one carries it.
    package let hardwareId: HidHardwareId?
    /// Standard or Direct, why, and a Direct pad's report rate.
    package let inputPath: SlotInputPath?
    /// The controller data's record for the pad's identity; nil when none
    /// matched or the identity is unknown.
    package var record: ControllerRecord?
    /// The pad's transport, the Direct path's or the census device's.
    package var transport: ControllerTransport?
    /// The same in IOKit's words, with the Bluetooth link.
    package var hidTransport: HidTransport?
    /// The census device under the pad, for its product and manufacturer.
    package var device: HidDeviceFacts?
    /// What IOKit said of its hardware: the Direct interface's, else what
    /// the devices matched to it by name agree on.
    package var hardwareDetail: HidHardwareDetail?
    /// Its USB device's raw descriptors, read without opening it; nil off
    /// USB and where IOKit hands none over.
    package var usbDescriptors: UsbRawDescriptors?
    /// The record's issues that apply to this Mac and this transport.
    package var issues: [ControllerIssue] = []

    package var id: String {
        slot.id
    }

    package init(
        slot: ControllerSlot,
        wire: SlotWireFacts?,
        audio: PadAudioDiagnostics? = nil,
        backgroundInput: Bool = false,
        hardwareId: HidHardwareId? = nil,
        inputPath: SlotInputPath? = nil
    ) {
        self.slot = slot
        self.wire = wire
        self.audio = audio
        self.backgroundInput = backgroundInput
        self.hardwareId = hardwareId
        self.inputPath = inputPath
    }
}

package struct DiagnosticsSnapshot: Equatable {
    package var hosts: [HostDiagnostics] = []
    package var pads: [PadDiagnostics] = []
    /// Every HID game device on the Mac, GameController's and the rest.
    package var inputDevices: [HidDeviceFacts] = []
    /// The controller data in force and its last check.
    package var controllerDb = ControllerDbStatus()
    /// The data's words, for the names and issues the cards show.
    package var controllerStrings = ControllerStrings(tables: [:])

    package init(hosts: [HostDiagnostics] = [], pads: [PadDiagnostics] = [], inputDevices: [HidDeviceFacts] = []) {
        self.hosts = hosts
        self.pads = pads
        self.inputDevices = inputDevices
    }
}

/// What the app sees right now, for the Diagnostics window: every figure is
/// one the rest of the app already acts on, not a second measurement. The
/// ack-fed numbers change without a publication, so a 1 Hz tick re-reads
/// them while the window is open; `start` arms it and `stop` ends it. The
/// HID census watches only while the window is open, and a device's match
/// or removal re-reads at once.
@MainActor
package final class DiagnosticsSource: StateSource<DiagnosticsSnapshot> {

    private let wifi: WifiConnectionManager
    private let hub: ConnectionHub
    private let moonlight: MoonlightConnectionManager?
    private let census: HidCensusReading
    private var slots: () -> [ControllerSlot] = { [] }
    private var audio: (String) -> PadAudioDiagnostics? = { _ in nil }
    private var backgroundInput: () -> Bool = { false }
    private var inputPath: (String) -> SlotInputPath? = { _ in nil }
    private var controllerIndex: () -> ControllerIndex = { ControllerIndex(BundledControllerDb.empty, source: .bundled) }
    private var controllerDb: () -> ControllerDbStatus = { ControllerDbStatus() }
    private let issueHost: IssueHost
    private var onTick: () -> Void = {}
    private var timer: DispatchSourceTimer?
    /// The pages watching: Diagnostics and the report it opens may overlap
    /// as one replaces the other, so the source stops with the last.
    private var watchers = 0

    private let descriptors: UsbDescriptorReading
    /// Each USB device's raw descriptors, read once: they do not change
    /// while the device stays, and a new attach is a new entry.
    private var readDescriptors: [UInt64: ReadDescriptors] = [:]

    init(
        wifi: WifiConnectionManager,
        hub: ConnectionHub,
        moonlight: MoonlightConnectionManager? = nil,
        census: HidCensusReading = IOKitHidCensus(),
        issueHost: IssueHost = IssueHost(model: "", osMajor: 0),
        descriptors: UsbDescriptorReading = IOKitUsbDescriptorReader()
    ) {
        self.descriptors = descriptors
        self.issueHost = issueHost
        self.wifi = wifi
        self.hub = hub
        self.moonlight = moonlight
        self.census = census
        super.init(initial: DiagnosticsSnapshot())
    }

    /// The slot list to read, set once the owner has one.
    func useSlots(_ provider: @escaping () -> [ControllerSlot]) {
        slots = provider
    }

    /// Each pad's audio by slot id, set once the owner has a pipeline.
    func useAudio(_ provider: @escaping (String) -> PadAudioDiagnostics?) {
        audio = provider
    }

    /// Whether the controller framework delivers input in the background, set once the owner has a bridge.
    func useBackgroundInput(_ provider: @escaping () -> Bool) {
        backgroundInput = provider
    }

    /// Each slot's input path, and the work that rides the same tick (the
    /// Direct pads' raw rates), set once the owner has both.
    func useInputPaths(_ provider: @escaping (String) -> SlotInputPath?, tick: @escaping () -> Void) {
        inputPath = provider
        onTick = tick
    }

    /// The controller data in force and its status, set once the owner has them.
    func useControllerData(index: @escaping () -> ControllerIndex, status: @escaping () -> ControllerDbStatus) {
        controllerIndex = index
        controllerDb = status
    }

    override package func start() {
        MainActor.assumeIsolated {
            watchers += 1
            census.start { [weak self] in self?.refresh() }
            refresh()
            arm()
        }
    }

    override package func stop() {
        MainActor.assumeIsolated {
            watchers = max(0, watchers - 1)
            guard watchers == 0 else { return }
            timer?.cancel()
            timer = nil
            census.stop()
        }
    }

    package func refresh() {
        onTick()
        setState(compose())
    }

    private func arm() {
        guard timer == nil else { return }
        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(deadline: .now() + .seconds(1), repeating: .seconds(1))
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.refresh() }
        }
        source.resume()
        timer = source
    }

    private func compose() -> DiagnosticsSnapshot {
        let hosts = hub.connections.map { summary in
            HostDiagnostics(
                summary: summary,
                facts: wifi.get(summary.id).map(hostSessionFacts) ?? HostSessionFacts.resting(id: summary.id),
                moonlight: moonlightFacts(summary)
            )
        }
        let inBackground = backgroundInput()
        let devices = census.devices()
        let index = controllerIndex()
        let pads = slots().map { slot in
            let path = inputPath(slot.id)
            let pad = PadDiagnostics(
                slot: slot,
                wire: slot.boundConnectionId.flatMap { wifi.get($0) }.flatMap { slotWireFacts(of: $0, slotId: slot.id) },
                audio: audio(slot.id),
                backgroundInput: inBackground,
                hardwareId: path?.hardwareId ?? hardwareId(forPadNamed: slot.name, in: devices),
                inputPath: path
            )
            return withDescriptors(withRecord(pad, index: index, devices: devices, host: issueHost), devices: devices)
        }
        var snapshot = DiagnosticsSnapshot(hosts: hosts, pads: pads, inputDevices: devices)
        snapshot.controllerDb = controllerDb()
        snapshot.controllerStrings = index.strings
        return snapshot
    }

    /// The pad with its USB device's raw descriptors: the device of the
    /// Direct interface it reads, else what the devices matched to it by
    /// name agree on (twins of a model share theirs). No fingerprint: it
    /// covers the device descriptor as the bus delivered it, and the Mac's is
    /// rebuilt from the registry, never proven equal (`Tests/PARITY.md`).
    private func withDescriptors(_ pad: PadDiagnostics, devices: [HidDeviceFacts]) -> PadDiagnostics {
        let ids = usbDeviceIds(of: pad, devices: devices)
        let read = agreed(ids.map { $0.flatMap(rawDescriptors) }).flatMap(\.self)
        var known = pad
        known.usbDescriptors = read
        known.hardwareDetail?.descriptorSha256 = nil
        known.hardwareDetail?.endpoints = pad.hardwareDetail?.endpoints ?? hidEndpoints(read, detail: pad.hardwareDetail)
        return known
    }

    /// A HID pad's interrupt endpoints, from its configuration descriptor:
    /// the interface its HID device is.
    private func hidEndpoints(_ descriptors: UsbRawDescriptors?, detail: HidHardwareDetail?) -> BundleEndpoints? {
        guard let descriptors, let number = detail?.interfaceNumber else { return nil }
        return interruptEndpoints(descriptors, interfaceNumber: number)
    }

    /// A Direct pad's own USB device, or those of the devices matched to a
    /// GameController pad by name.
    private func usbDeviceIds(of pad: PadDiagnostics, devices: [HidDeviceFacts]) -> [UInt64?] {
        guard pad.inputPath?.source != .direct else { return [pad.inputPath?.usbDeviceId] }
        return carriers(ofPadNamed: pad.slot.name, in: devices).map(\.usbDeviceId)
    }

    private func rawDescriptors(_ registryId: UInt64) -> UsbRawDescriptors? {
        if let known = readDescriptors[registryId] {
            return known.raw
        }
        let read = descriptors.rawDescriptors(ofUsbDevice: registryId)
        readDescriptors[registryId] = ReadDescriptors(raw: read)
        return read
    }

    /// A Moonlight host's session, read off its connection when one exists
    /// this run and resting on what its probe said when none does.
    private func moonlightFacts(_ summary: ConnectionSummary) -> MoonlightHostDiagnostics? {
        guard summary.kind == .moonlight, let moonlight else { return nil }
        let info = moonlight.hostFacts[summary.id]
        guard let connection = moonlight.get(summary.id) else { return .resting(info: info) }
        return .read(connection, info: info)
    }
}

/// What reading a USB device's raw descriptors gave, none included.
private struct ReadDescriptors {
    let raw: UsbRawDescriptors?
}

/// The pad with its census device, its transport, the data's record for its
/// identity and the record's issues that apply here.
func withRecord(_ pad: PadDiagnostics, index: ControllerIndex, devices: [HidDeviceFacts], host: IssueHost) -> PadDiagnostics {
    var known = pad
    let device = pad.hardwareId.flatMap { id in devices.first { $0.hardwareId == id } }
    let hidTransport = pad.inputPath?.transport ?? transport(forPadNamed: pad.slot.name, in: devices)
    let transport = controllerTransport(hidTransport)
    known.device = device
    known.hidTransport = hidTransport
    known.transport = transport
    known.hardwareDetail = pad.inputPath?.hardware ?? hardwareDetail(forPadNamed: pad.slot.name, in: devices)
    guard let id = pad.hardwareId else { return known }
    let vendorId = UInt16(clamping: id.vendorId)
    let productId = UInt16(clamping: id.productId)
    known.record = index.record(vendorId: vendorId, productId: productId, transport: transport)
    known.issues = known.record.map { issuesApplying($0.issues, transport: transport, host: host) } ?? []
    return known
}
