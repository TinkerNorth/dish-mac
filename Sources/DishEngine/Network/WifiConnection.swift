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
    @Published private(set) var boundSlotId: String?
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
    /// The bound slot changed while live; the manager converges over REST.
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
    /// Whether the satellite confirmed the bound slot plugged. The desire can
    /// exist before the bitmap bit does, and that gap is not drift.
    private(set) var slotApplied = false

    /// What the last negotiation said about the satellite's version.
    @Published private(set) var protocolCompat: ProtocolCompat = .unknown
    /// The session grant's word on host mouse control, for the diagnostics.
    private(set) var mouseControlGranted = false
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
    private var pendingControllerType = 0
    private var pendingCapabilities: ControllerCapabilities = .none
    /// The bound pad's family, so the manager can re-resolve the type it is
    /// emulated as when a catalog or a pick arrives.
    private(set) var boundFamily: PadFamily = .other
    private var forwardingFlags = ForwardingFlags()
    /// Cached so a reconnect's fresh client gets every handler again.
    var returnPaths = ReturnPathHandlers()

    nonisolated static let defaultCtrlIndex = 0

    init(id: String, server: DiscoveredServer, tickIntervalNs: UInt64 = 1_000_000_000) {
        self.id = id
        self.server = server
        self.tickIntervalNs = tickIntervalNs
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

    /// The whole desired controller set for the session PUT: the bound slot
    /// as one descriptor, or nil for a valid zero-controller session. The
    /// caps and the touchpad mode say what the pad has AND the user allows.
    var desiredDescriptor: ControllerDescriptor? {
        guard boundSlotId != nil else { return nil }
        var descriptor = ControllerDescriptor()
        descriptor.ctrlIdx = Self.defaultCtrlIndex
        descriptor.type = UInt8(truncatingIfNeeded: pendingControllerType)
        descriptor.caps = descriptorCaps(pendingCapabilities, forwardingFlags)
        descriptor.touchpadMode = descriptorTouchpadMode(pendingCapabilities, forwardingFlags)
        return descriptor
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
        if boundSlotId != nil, !slotApplied {
            onTopologyChanged?()
        }
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
            expectedBitmap: expectedBitmap(appliedBeliefSlots())
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
        slotApplied = false
        mouseControlGranted = false
        hooks = SessionHooks()
        latencyOneWayMs = nil
        latencySamples = 0
        state = endState
    }

    // MARK: - Reconcile state

    func markSlotApplied() {
        if boundSlotId != nil { slotApplied = true }
    }

    func setLastAppliedEpoch(_ epoch: Int) {
        lastAppliedEpoch = epoch
    }

    func setMouseControlGranted(_ granted: Bool) {
        mouseControlGranted = granted
    }

    func setReconcileInFlight(_ inFlight: Bool) {
        reconcileInFlight = inFlight
    }

    func desiredSlots() -> [DesiredSlot] {
        guard let descriptor = desiredDescriptor else { return [] }
        return [DesiredSlot(ctrlIdx: UInt8(truncatingIfNeeded: descriptor.ctrlIdx), type: descriptor.type)]
    }

    private func appliedBeliefSlots() -> [DesiredSlot] {
        slotApplied ? desiredSlots() : []
    }

    // MARK: - Slot binding

    func attachSlot(_ slotId: String, controllerType: Int, capabilities: ControllerCapabilities, family: PadFamily = .other) {
        boundSlotId = slotId
        pendingControllerType = controllerType
        pendingCapabilities = capabilities
        boundFamily = family
        if hasLiveSession { onTopologyChanged?() }
    }

    /// The type the pad is emulated as changed. The descriptor is sent
    /// whole, so a new type re-sends it while the slot is bound and live.
    func setControllerType(_ type: Int) {
        guard type != pendingControllerType else { return }
        pendingControllerType = type
        if boundSlotId != nil, hasLiveSession { onTopologyChanged?() }
    }

    /// A switch flipped in Settings. The descriptor is always sent whole, so
    /// a changed claim re-sends it while a slot is bound and live.
    func setForwardingFlags(_ flags: ForwardingFlags) {
        guard flags != forwardingFlags else { return }
        forwardingFlags = flags
        if boundSlotId != nil, hasLiveSession { onTopologyChanged?() }
    }

    /// The belief updates at once; a failed DELETE self-heals via reconcile.
    func detachSlot() {
        if boundSlotId == nil { return }
        boundSlotId = nil
        slotApplied = false
        if hasLiveSession { onTopologyChanged?() }
    }

    func setSlotSyncInFlight(_ inFlight: Bool) {
        isRegisteringController = inFlight
    }

    // MARK: - Streams (controller callback threads)

    nonisolated func sendReport(_ report: GamepadReport) {
        guard let live = clientRef.get() else { return }
        live.sendReport(controllerIndex: Self.defaultCtrlIndex, report: report)
    }

    nonisolated func sendMotion(_ sample: MotionSample, timestampDeltaUs: UInt32) {
        guard let live = clientRef.get() else { return }
        live.sendMotion(controllerIndex: Self.defaultCtrlIndex, sample: sample, timestampDeltaUs: timestampDeltaUs)
    }

    nonisolated func sendBattery(level: UInt8, status: BatteryStatus) {
        guard let live = clientRef.get() else { return }
        live.sendBattery(controllerIndex: Self.defaultCtrlIndex, level: level, status: status)
    }

    nonisolated func sendTouchpad(sample: TouchpadSample, eventTimeMs: UInt32) {
        guard let live = clientRef.get() else { return }
        live.sendTouchpad(controllerIndex: Self.defaultCtrlIndex, sample: sample, eventTimeMs: eventTimeMs)
    }

    /// The mic lane, from the capture thread; nothing while no session.
    nonisolated func sendMicAudio(seq: UInt16, opus: Data) {
        guard let live = clientRef.get() else { return }
        live.sendMicAudio(AudioFrame(controllerIndex: UInt8(Self.defaultCtrlIndex), seq: seq, opus: opus))
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
