// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Combine
import DishCore
import Foundation

/// How far one satellite's live link has progressed. The UI-facing
/// `LinkState` folds pairing and discovery in on top of this.
///
/// - `idle`: no session. `linking`: the handshake is in flight. `live`:
///   acks flowing. `faltering`: live, but the missed-ack count reached the
///   "not responding" threshold. `stale`: acks stopped while a key is still
///   held, and a silent retry is pending.
enum SessionState {
    case idle
    case linking
    case live
    case faltering
    case stale
}

/// The manager's policy callbacks, installed at `markConnected`. The
/// connection observes the wire and calls out; every decision lives in the
/// manager. All three fire on the main actor from the alive tick.
struct SessionHooks {
    /// Five consecutive missed acks.
    var onDead: () -> Void = {}
    /// An authenticated close-notify reason byte, raw so an unknown future
    /// reason still routes.
    var onClose: (UInt8) -> Void = { _ in }
    /// The enriched ack's epoch or bitmap drifted from the applied belief.
    var reconcile: () -> Void = {}
}

/// One live or potential session to a satellite. Owns the UDP client while
/// live; topology rides REST through the manager, never UDP.
@MainActor
package final class WifiConnection: ObservableObject, Identifiable {

    package let id: String
    @Published private(set) var server: DiscoveredServer
    @Published private(set) var state: SessionState = .idle
    /// The pads this session carries, each on its own controller index.
    @Published private(set) var slotTable = SatelliteSlotTable()
    /// True while the manager's per-slot PUT or DELETE is in flight.
    @Published private(set) var isRegisteringController = false
    /// Median heartbeat round trip halved, to 0.1 ms, nil until the first
    /// paired ack of the session.
    @Published private(set) var latencyOneWayMs: Double?
    @Published private(set) var latencySamples = 0

    private(set) var connectionId: String?
    /// Written on the main actor, read on the controller callback threads.
    private let clientRef = ClientRef()
    var client: SatelliteClient? {
        clientRef.get()
    }

    /// The slot id the satellite refused to plug, so the hub rolls back.
    let slotRegistrationFailed = PassthroughSubject<String, Never>()
    /// A bound slot changed while live; the manager converges over REST.
    var onTopologyChanged: (() -> Void)?
    /// The send counter crossed the re-key threshold; fires once per approach.
    var onRekeyNeeded: (() -> Void)?
    /// Observational relay of a parsed close reason; policy rides the hooks.
    var onSessionClose: ((CloseReason) -> Void)?

    private(set) var lastHeartbeatAck: HeartbeatAck?
    /// The epoch of the topology we last applied; -1 while no session.
    private(set) var lastAppliedEpoch = -1
    /// Set when the manager's reconcile GET launches, cleared when it lands.
    private(set) var reconcileInFlight = false
    /// The controller indices whose descriptor changed while live and wait
    /// for the manager's per-slot PUT or DELETE.
    private var pendingIndices: Set<Int> = []

    /// What the last negotiation said about the satellite's version.
    @Published private(set) var protocolCompat: ProtocolCompat = .unknown
    /// The session grant's word on host mouse control, for the diagnostics.
    private(set) var mouseControlGranted = false
    /// What the satellite will carry of the pad's audio, from its probe at
    /// session open; nothing until then.
    @Published private(set) var hostAudio = HostAudioVerdict.none
    /// Each controller index's mic lane sequence, monotonic for this
    /// connection's lifetime: across a mute, a re-key and a reconnect, so the
    /// satellite's reorder window never reads a restart as a burst of late
    /// frames.
    let micSeqs = (0 ..< SatelliteSlots.maxPerSatellite).map { _ in AtomicInt(0) }
    /// Each pad's audio handlers by controller index, for the receive queue.
    let padAudio = PadAudioTable()
    /// The version the live session speaks; the floor while no session.
    private(set) var settledProtocolVersion = ProtocolConstants.protocolVersionMin
    /// The version the next pairing or session PUT offers. A 409 whose range
    /// still overlaps ours lowers it, and the lowered offer sticks to this
    /// connection so a retry never repeats the rejected number.
    private(set) var offeredProtocolVersion = ProtocolConstants.protocolVersion

    private var hooks = SessionHooks()
    private let tickIntervalNs: UInt64
    private var aliveTask: Task<Void, Never>?
    private var rekeyRequested = false
    /// Cached so a reconnect's fresh client gets every handler again.
    var returnPaths: ReturnPathHandlers

    init(id: String, server: DiscoveredServer, tickIntervalNs: UInt64 = 1_000_000_000) {
        self.id = id
        self.server = server
        self.tickIntervalNs = tickIntervalNs
        returnPaths = ReturnPathHandlers(audio: padAudio)
    }

    package static func idFor(_ server: DiscoveredServer) -> String {
        server.id
    }

    /// Linking, live or faltering: a connect must not restart this.
    var hasSession: Bool {
        state == .live || state == .linking || state == .faltering
    }

    /// Live or faltering: REST may be healthy while UDP acks are lossy, so
    /// converges, re-keys and reconciles still run.
    var hasLiveSession: Bool {
        state == .live || state == .faltering
    }

    func updateServer(_ server: DiscoveredServer) {
        self.server = server
    }

    func markConnecting() {
        if hasLiveSession { return }
        state = .linking
    }

    // MARK: - The pads

    /// Every edit of the pads lands here, published once: each index whose
    /// descriptor the edit changed converges while live.
    @discardableResult
    func editSlots<Result>(_ edit: (inout SatelliteSlotTable) -> Result) -> Result {
        let before = slotTable.descriptorsByIndex()
        var table = slotTable
        let result = edit(&table)
        if table != slotTable { slotTable = table }
        convergeIndices(changedIndices(before, table.descriptorsByIndex()))
        return result
    }

    /// Queue the indices for the manager's per-slot routes; nothing while no
    /// session, whose next PUT carries the whole set.
    func convergeIndices(_ indices: Set<Int>) {
        guard hasLiveSession, !indices.isEmpty else { return }
        pendingIndices.formUnion(indices)
        onTopologyChanged?()
    }

    /// The indices waiting for the manager, handed over once.
    func takePendingIndices() -> Set<Int> {
        let taken = pendingIndices
        pendingIndices = []
        return taken
    }

    // MARK: - Protocol version

    /// A 409 left a lower version to offer.
    func setOfferedProtocolVersion(_ version: Int) {
        offeredProtocolVersion = version
    }

    /// The PUT settled: the frames key off this, and the chip follows.
    func adoptProtocol(_ outcome: ProtocolOutcome) {
        settledProtocolVersion = outcome.settledVersion
        protocolCompat = compatForOutcome(outcome)
    }

    /// A terminal 409: the row keeps saying which end must update.
    func setProtocolCompat(_ compat: ProtocolCompat) {
        protocolCompat = compat
    }

    // MARK: - Session lifecycle

    /// Go live: start the receive loop, the heartbeat and the alive tick.
    /// `epoch` is the PUT response's epoch, the reconcile baseline.
    func markConnected(client: SatelliteClient, connectionId: String, epoch: Int, hooks: SessionHooks) {
        guard state == .linking else { return }
        clientRef.set(client)
        self.connectionId = connectionId
        self.hooks = hooks
        state = .live
        lastHeartbeatAck = nil
        lastAppliedEpoch = epoch
        reconcileInFlight = false
        rekeyRequested = false
        latencyOneWayMs = nil
        latencySamples = 0
        installClientHandlers(client)
        client.startReceiveLoop()
        client.startHeartbeat()
        startAliveTick()
        convergeSlotAttachedWhileLinking()
    }

    private func installClientHandlers(_ client: SatelliteClient) {
        returnPaths.install(on: client)
        client.onSessionClose = { [weak self] reason in
            Task { @MainActor [weak self] in
                self?.onSessionClose?(reason)
            }
        }
    }

    private func startAliveTick() {
        let interval = tickIntervalNs
        aliveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: interval)
                guard !Task.isCancelled, let self else { return }
                if self.aliveTick() == .sessionEnded { return }
            }
        }
    }

    /// A slot attached while linking missed the PUT's descriptor snapshot.
    private func convergeSlotAttachedWhileLinking() {
        convergeIndices(slotTable.unappliedIndices)
    }

    enum TickOutcome {
        case running
        case sessionEnded
    }

    /// One alive poll: a latched close first, then death, then the live and
    /// faltering flip, then the readouts and the drift check.
    @discardableResult
    func aliveTick() -> TickOutcome {
        guard let live = clientRef.get() else {
            hooks.onDead()
            return .sessionEnded
        }
        tickSnapshotsAndRekey(live)
        let closeReason = live.sessionCloseReason.get()
        if closeReason >= 0 {
            hooks.onClose(UInt8(truncatingIfNeeded: closeReason))
            return .sessionEnded
        }
        guard live.connectionAlive.get() else {
            hooks.onDead()
            return .sessionEnded
        }
        flipLiveOrFaltering(live)
        publishLatency(live)
        evaluateReconcile()
        return .running
    }

    private func flipLiveOrFaltering(_ live: SatelliteClient) {
        let faltering = live.missedAcks.get() >= ProtocolConstants.heartbeatMissNotResponding
        let want: SessionState = faltering ? .faltering : .live
        if state != want, hasLiveSession {
            state = want
        }
    }

    /// Mutate only when the displayed figure moved, so the tick does not
    /// churn observers.
    private func publishLatency(_ live: SatelliteClient) {
        let snapshot = live.latencySnapshot()
        let rounded = snapshot.p50OneWayMs.map { ($0 * 10).rounded() / 10 }
        if rounded != latencyOneWayMs { latencyOneWayMs = rounded }
        if snapshot.samples != latencySamples { latencySamples = snapshot.samples }
    }

    private func evaluateReconcile() {
        guard !reconcileInFlight, let ack = lastHeartbeatAck else { return }
        let drifted = reconcileNeeded(
            serverEpoch: Int(ack.epoch),
            serverBitmap: Int(ack.bitmap),
            lastAppliedEpoch: lastAppliedEpoch,
            expectedBitmap: expectedBitmap(slotTable.appliedSlots())
        )
        if drifted {
            hooks.reconcile()
        }
    }

    private func tickSnapshotsAndRekey(_ live: SatelliteClient) {
        lastHeartbeatAck = live.heartbeatAckSnapshot()
        let needsRekey = counterNeedsRepush(live.sendCounter)
        if needsRekey, !rekeyRequested {
            rekeyRequested = true
            onRekeyNeeded?()
        }
        if !needsRekey {
            rekeyRequested = false
        }
    }

    func markDisconnected() {
        teardown(parkedOn: .idle)
    }

    /// Death-path teardown: the row reads "Unsteady" through the backoff
    /// window instead of flicking straight to offline.
    func parkStaleAwaitingRetry() {
        teardown(parkedOn: .stale)
    }

    private func teardown(parkedOn endState: SessionState) {
        let existing = clientRef.get()
        let nothingToTearDown = state == .idle && existing == nil && endState == .idle
        if nothingToTearDown { return }
        aliveTask?.cancel()
        aliveTask = nil
        isRegisteringController = false
        existing?.closeSocket()
        clientRef.set(nil)
        connectionId = nil
        lastHeartbeatAck = nil
        lastAppliedEpoch = -1
        reconcileInFlight = false
        pendingIndices = []
        slotTable.clearApplied()
        mouseControlGranted = false
        hostAudio = .none
        hooks = SessionHooks()
        latencyOneWayMs = nil
        latencySamples = 0
        state = endState
    }

    // MARK: - Reconcile state

    func setLastAppliedEpoch(_ epoch: Int) {
        lastAppliedEpoch = epoch
    }

    func setMouseControlGranted(_ granted: Bool) {
        mouseControlGranted = granted
    }

    func setHostAudio(_ verdict: HostAudioVerdict) {
        hostAudio = verdict
    }

    func setReconcileInFlight(_ inFlight: Bool) {
        reconcileInFlight = inFlight
    }

    func setSlotSyncInFlight(_ inFlight: Bool) {
        isRegisteringController = inFlight
    }

    // MARK: - Streams (controller callback threads)

    nonisolated func sendReport(_ report: GamepadReport, controllerIndex: Int) {
        guard let live = clientRef.get() else { return }
        live.sendReport(controllerIndex: controllerIndex, report: report)
    }

    nonisolated func sendMotion(_ sample: MotionSample, timestampDeltaUs: UInt32, controllerIndex: Int) {
        guard let live = clientRef.get() else { return }
        live.sendMotion(controllerIndex: controllerIndex, sample: sample, timestampDeltaUs: timestampDeltaUs)
    }

    nonisolated func sendBattery(level: UInt8, status: BatteryStatus, controllerIndex: Int) {
        guard let live = clientRef.get() else { return }
        live.sendBattery(controllerIndex: controllerIndex, level: level, status: status)
    }

    nonisolated func sendTouchpad(sample: TouchpadSample, eventTimeMs: UInt32, controllerIndex: Int) {
        guard let live = clientRef.get() else { return }
        live.sendTouchpad(controllerIndex: controllerIndex, sample: sample, eventTimeMs: eventTimeMs)
    }

    /// One pad's mic lane, from the capture thread; nothing while no session
    /// or for an index beyond the cap. The sequence advances only for a
    /// packet that goes out.
    nonisolated func sendMicAudio(opus: Data, controllerIndex: Int) {
        guard let live = clientRef.get(), micSeqs.indices.contains(controllerIndex) else { return }
        let seq = UInt16(truncatingIfNeeded: micSeqs[controllerIndex].incrementAndGet() - 1)
        live.sendMicAudio(AudioFrame(controllerIndex: UInt8(truncatingIfNeeded: controllerIndex), seq: seq, opus: opus))
    }
}

/// Lock-guarded holder for the live client: written on the main actor,
/// read on the controller callback threads.
final class ClientRef: @unchecked Sendable {
    private var value: SatelliteClient?
    private var lock = os_unfair_lock_s()

    func get() -> SatelliteClient? {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return value
    }

    func set(_ newValue: SatelliteClient?) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        value = newValue
    }
}
