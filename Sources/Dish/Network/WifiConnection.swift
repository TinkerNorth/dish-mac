// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Combine
import DishCore
import Foundation

/// Internal wire-level session state for one Satellite connection — the
/// "Presence" axis (per the shared nomenclature): how far the live network
/// link has progressed for *this* connection.
///
/// Distinct from the UI-facing `LinkState` (in `ConnectionHub`), which folds
/// pairing/discovery in on top of this.
///
/// - `idle` — no live session (paired or not).
/// - `linking` — pair+auth handshake / `markConnecting()` is in flight;
///   native socket not yet open. UI chip: "Connecting…".
/// - `live` — native socket open, heartbeat ACKs flowing. UI chip: "Online".
/// - `faltering` — `live`, but the consecutive missed-ack count has reached
///   the "not responding" threshold (2) without hitting death (5). The alive
///   tick flips `live` ⇄ `faltering` from `SatelliteClient.missedAcks`
///   (contract §Liveness; gap G15). UI chip: "Unsteady".
/// - `stale` — heartbeats stopped arriving but we still hold a shared key.
///   The manager attempts a silent re-handshake (no user-visible error)
///   using the saved key; only if that fails does the chip fall back to a
///   resting `.saved` / `.ready` and surface a banner if the retry was
///   user-initiated. Ports the `RETRY_AFTER_DEATH` path from
///   `dish-android/source/connection/SatelliteConnectionManager.kt`.
enum SessionState { case idle, linking, live, faltering, stale }

/// Control-plane callbacks installed by `WifiConnectionManager` at
/// `markConnected` (dish-linux `SessionHooks`; PLAN D2 "humble object"): the
/// connection OBSERVES the wire and calls out — every decision (backoff
/// scheduling, close-reason policy, reconcile HTTP) lives in the manager.
/// All hooks fire on the main actor from the 1 Hz alive tick. Defaults are
/// no-ops so a connection is safely constructible without a manager.
struct SessionHooks {
    /// Heartbeat death (contract §Liveness: 5 consecutive misses) — the
    /// manager tears the session down and schedules the backoff retry.
    var onDead: () -> Void = {}
    /// An authenticated MSG_SESSION_CLOSE reason byte latched on the client —
    /// the manager maps it through `DishCore.closeAction(forReasonByte:)`
    /// (unpaired drops the key, replaced stays down, shutdown/kicked re-enter
    /// backoff). Raw byte so an unknown FUTURE reason still routes.
    var onClose: (UInt8) -> Void = { _ in }
    /// The enriched ack's epoch/bitmap drifted from what we last applied —
    /// the manager runs the GET-then-converge reconcile. Single-flight is
    /// guarded by `reconcileInFlight` on the connection.
    var reconcile: () -> Void = {}
}

/// A single live or potential WiFi session to one Satellite server. Owns a
/// `SatelliteClient` instance (the protocol-1 UDP data plane) once `live`.
/// Topology changes never ride UDP: the bound slot surfaces as
/// `desiredDescriptor` and the manager converges it over REST (session PUT /
/// per-slot routes — contract §Session). Mirrors `WifiConnection.kt`.
@MainActor
final class WifiConnection: ObservableObject, Identifiable {

    let id: String
    @Published private(set) var server: DiscoveredServer
    @Published private(set) var state: SessionState = .idle
    @Published private(set) var boundSlotId: String?
    /// True while the manager's per-slot PUT/DELETE for this connection is in
    /// flight. The dashboard observes this to show a spinner.
    @Published private(set) var isRegisteringController = false

    /// Server-issued connection id, valid while `live`.
    private(set) var connectionId: String?
    /// Shared reference holder for the live `SatelliteClient`. Writes happen
    /// on the main actor in `markConnected`/`markDisconnected`; reads happen
    /// on the GameController callback thread via `sendReport`. The holder is
    /// lock-protected so swapping is race-free without a main-actor hop.
    private let clientRef = ClientRef()
    var client: SatelliteClient? {
        clientRef.get()
    }

    /// Human-readable controller-registration errors (apply failures from the
    /// REST slot routes). Listened to by `WifiConnectionManager` and forwarded
    /// into the global event stream so the UI can surface them inline.
    let errorMessages = PassthroughSubject<String, Never>()
    /// Emitted with the slot id when the server can't apply the bound slot so
    /// `ConnectionHub` can roll back the local binding.
    let slotRegistrationFailed = PassthroughSubject<String, Never>()

    /// Fired (main actor) when the bound slot changes while `live` — the
    /// manager converges the server via the per-slot REST routes.
    var onTopologyChanged: (() -> Void)?
    /// Fired (main actor, once per approach) when the send counter crosses
    /// the proactive re-PUT threshold — the manager re-PUTs for fresh
    /// token/salt/key before the counter can exhaust (gap G4).
    var onRekeyNeeded: (() -> Void)?
    /// Forwarded (main actor) from the client's authenticated
    /// MSG_SESSION_CLOSE parse — an OBSERVATIONAL relay for UI/tests.
    /// Teardown policy does NOT ride this: the alive tick's latched-reason
    /// branch dispatches `SessionHooks.onClose` so close handling has exactly
    /// one policy path (gap G10).
    var onSessionClose: ((CloseReason) -> Void)?

    /// Latest enriched heartbeat ack, refreshed by the 1 Hz alive tick while
    /// `live` — the reconcile driver's polled input (gap G9).
    private(set) var lastHeartbeatAck: HeartbeatAck?

    /// One-way latency readout cached from the alive tick (median heartbeat
    /// RTT halved, rounded to 0.1 ms so the published value only moves when
    /// the displayed figure does — dish-linux `telemetryChanged` discipline).
    /// Nil until the first paired ack of the session (gap G13 readout).
    @Published private(set) var latencyOneWayMs: Double?
    /// RTT samples currently in the latency window (0 until the first ack).
    @Published private(set) var latencySamples = 0

    /// Manager-installed policy callbacks, valid while a session is up.
    private var hooks = SessionHooks()
    /// The session epoch we last applied (from the session PUT / per-slot PUT
    /// response / a benign reconcile). Compared against the enriched ack's
    /// epoch by the alive tick; −1 while no session (gap G9).
    private(set) var lastAppliedEpoch = -1
    /// Single-flight guard for the manager's reconcile: true from the moment
    /// the drift hook fires until the manager's GET lands. The alive tick
    /// skips re-triggering while set.
    private(set) var reconcileInFlight = false
    /// Whether the server confirmed the bound slot applied (session PUT or
    /// per-slot PUT reported the slot live) — dish-linux `controllerAdded_`.
    /// This is the expected-bitmap belief: during a converge's flight the
    /// DESIRE exists but no bitmap bit does yet, and treating want-as-applied
    /// would false-positive the drift check on every tick.
    private(set) var slotApplied = false

    /// Alive-tick cadence. Injectable so lifecycle tests can park the loop
    /// (`.max`) and drive `aliveTick()` deterministically.
    private let tickIntervalNs: UInt64

    private var aliveTask: Task<Void, Never>?
    /// Single-fire latch for `onRekeyNeeded`: armed again only after the
    /// re-key lands (the fresh counter drops back under the threshold), so a
    /// slow / failing re-PUT isn't re-requested every tick.
    private var rekeyRequested = false
    private var pendingControllerType = 0
    /// Whether the bound physical controller exposes an addressable RGB light
    /// (`GCController.light != nil`). Captured at bind time and folded into
    /// the descriptor caps word as `CAP_LIGHTBAR`.
    private var pendingHasLight = false
    /// Whether the bound physical controller exposes a `GCMotion` IMU
    /// surface. Captured at bind time and folded into the descriptor caps
    /// word as `CAP_MOTION` — a pad with no IMU must not advertise that it
    /// streams motion.
    private var pendingHasMotion = false

    /// Set once during composition; re-applied to each fresh `SatelliteClient`
    /// in `markConnected` so we don't lose rumble across reconnects. The
    /// closure runs on the SatelliteClient's receive-loop dispatch queue.
    private var rumbleHandler: ((RumbleCommand) -> Void)?
    /// Same pattern for the decoupled `MSG_LIGHTBAR` return path.
    private var lightbarHandler: ((LightbarCommand) -> Void)?

    nonisolated static let defaultCtrlIndex = 0
    /// Descriptor capability bits always advertised: analog triggers
    /// (`CAP_ANALOG_TRIGGERS`) | rumble (`CAP_RUMBLE`). Every macOS-bridged
    /// extended gamepad has analog triggers and accepts the rumble return
    /// path. `CAP_MOTION` / `CAP_LIGHTBAR` are per-controller — see
    /// `capabilityWord`.
    nonisolated static let defaultCaps: UInt16 =
        ProtocolConstants.capAnalogTriggers | ProtocolConstants.capRumble

    /// The descriptor `caps` word for a controller: the fixed `defaultCaps`
    /// bits with `CAP_MOTION` / `CAP_LIGHTBAR` OR'd in only when the bound
    /// physical controller actually exposes an IMU / an addressable RGB
    /// light. Rides the REST descriptor's caps object (protocol-1; the UDP
    /// capability word is gone with opcode 0x0004). `internal` so the rule is
    /// unit-testable without standing up a live session.
    nonisolated static func capabilityWord(hasMotion: Bool, hasLight: Bool) -> UInt16 {
        var word = defaultCaps
        if hasMotion { word |= ProtocolConstants.capMotion }
        if hasLight { word |= ProtocolConstants.capLightbar }
        return word
    }

    init(id: String, server: DiscoveredServer, tickIntervalNs: UInt64 = 1_000_000_000) {
        self.id = id
        self.server = server
        self.tickIntervalNs = tickIntervalNs
    }

    static func idFor(_ server: DiscoveredServer) -> String {
        server.id
    }

    func updateServer(_ server: DiscoveredServer) {
        self.server = server
    }

    func markConnecting() {
        if state == .live || state == .faltering { return }
        state = .linking
    }

    /// The COMPLETE desired controller set for the declarative session PUT
    /// (contract §Session): the bound slot as a whole descriptor, or nil for
    /// a valid zero-controller session. `touchpadMode` stays `.off` until the
    /// per-type picker lands (W3-A) — matching the previous hardcoded Xbox
    /// target, which has no touchpad sink.
    var desiredDescriptor: ControllerDescriptor? {
        guard boundSlotId != nil else { return nil }
        var descriptor = ControllerDescriptor()
        descriptor.ctrlIdx = Self.defaultCtrlIndex
        descriptor.type = UInt8(truncatingIfNeeded: pendingControllerType)
        descriptor.caps = Self.capabilityWord(hasMotion: pendingHasMotion, hasLight: pendingHasLight)
        descriptor.touchpadMode = .off
        return descriptor
    }

    /// Promote to `live`. Starts the receive loop + heartbeat and the 1 Hz
    /// alive tick (close-notify policy, liveness/faltering, telemetry,
    /// enriched-ack reconcile poll, re-key poll).
    ///
    /// `epoch` is the session PUT response's applied-topology epoch — the
    /// reconcile compare's baseline. `hooks` are the manager's policy
    /// callbacks; the connection itself decides nothing (PLAN D2).
    func markConnected(
        client: SatelliteClient,
        connectionId: String,
        epoch: Int,
        hooks: SessionHooks
    ) {
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
        client.onRumble = rumbleHandler
        client.onLightbar = lightbarHandler
        client.onSessionClose = { [weak self] reason in
            // Receive-queue → main-actor hop; observational relay of the
            // parsed WHY (UI/tests). POLICY rides the alive tick's
            // latched-reason branch so close handling has exactly one
            // dispatch point (dish-linux onAliveTick).
            Task { @MainActor [weak self] in
                self?.onSessionClose?(reason)
            }
        }
        client.startReceiveLoop()
        client.startHeartbeat()

        let interval = tickIntervalNs
        aliveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: interval)
                guard !Task.isCancelled, let self else { return }
                if self.aliveTick() == .sessionEnded { return }
            }
        }

        // A slot attached while the session was still linking missed both the
        // session PUT's descriptor snapshot and the live-converge trigger —
        // fire the converge now. (When the PUT itself carried and applied the
        // slot, the manager calls `markSlotApplied()` before this method.)
        if boundSlotId != nil, !slotApplied {
            onTopologyChanged?()
        }
    }

    /// Whether an `aliveTick()` ended the session (a hook fired that will
    /// tear it down) — the alive loop stops looping on `.sessionEnded`.
    enum TickOutcome { case running, sessionEnded }

    /// One evaluation of the 1 Hz alive poll, in dish-linux `onAliveTick`
    /// order: latched close-notify FIRST (terminal-now, no death wait), then
    /// heartbeat death, then the live ⇄ faltering flip off the consecutive
    /// missed-ack count (contract §Liveness: "not responding" at 2, dead
    /// at 5), then telemetry + the reconcile drift check. Internal (not
    /// private) so lifecycle tests can drive transitions deterministically
    /// with the loop parked (`tickIntervalNs: .max`).
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
        let faltering = live.missedAcks.get() >= ProtocolConstants.heartbeatMissNotResponding
        let want: SessionState = faltering ? .faltering : .live
        if state != want, state == .live || state == .faltering {
            state = want
        }
        publishLatency(live)
        evaluateReconcile()
        return .running
    }

    /// Refresh the published latency readout, mutating only when the
    /// 0.1 ms-rounded figure (or the sample count) actually moved so the
    /// 1 Hz tick doesn't churn `objectWillChange` (gap G13 readout).
    private func publishLatency(_ live: SatelliteClient) {
        let snapshot = live.latencySnapshot()
        let rounded = snapshot.p50OneWayMs.map { ($0 * 10).rounded() / 10 }
        if rounded != latencyOneWayMs { latencyOneWayMs = rounded }
        if snapshot.samples != latencySamples { latencySamples = snapshot.samples }
    }

    /// Reconcile trigger (gap G9 policy side): does the enriched ack's
    /// epoch/bitmap indicate the server's applied topology drifted from what
    /// we believe applied? Drift calls out ONCE — the manager's hook flips
    /// `reconcileInFlight` synchronously and clears it when its GET lands.
    /// The rule itself is `DishCore.reconcileNeeded` — wired, not reimplemented.
    private func evaluateReconcile() {
        guard !reconcileInFlight, let ack = lastHeartbeatAck else { return }
        guard reconcileNeeded(
            serverEpoch: Int(ack.epoch),
            serverBitmap: Int(ack.bitmap),
            lastAppliedEpoch: lastAppliedEpoch,
            expectedBitmap: expectedBitmap(appliedBeliefSlots())
        ) else { return }
        hooks.reconcile()
    }

    /// One alive-tick's polling half: refresh the enriched-ack snapshot for
    /// the reconcile driver (G9) and fire the single-shot re-key request when
    /// the send counter approaches exhaustion (G4). Pure wiring — the
    /// threshold rule is `DishCore.counterNeedsRepush`.
    private func tickSnapshotsAndRekey(_ live: SatelliteClient) {
        lastHeartbeatAck = live.heartbeatAckSnapshot()
        if counterNeedsRepush(live.sendCounter) {
            if !rekeyRequested {
                rekeyRequested = true
                onRekeyNeeded?()
            }
        } else {
            rekeyRequested = false
        }
    }

    func markDisconnected() {
        teardown(parkedOn: .idle)
    }

    /// Death-path teardown: identical to `markDisconnected` but parks the
    /// wire state on `.stale` — "was live moments ago, holding a key, silent
    /// retry pending" — so the row chip reads Unsteady through the backoff
    /// window instead of flicking straight to Offline. Only if the retry
    /// itself fails does the chip fall to the resting `.saved`/`.ready`
    /// (gap G15; ports `SatelliteConnectionManager.kt`'s stale window).
    func parkStaleAwaitingRetry() {
        teardown(parkedOn: .stale)
    }

    private func teardown(parkedOn endState: SessionState) {
        let existing = clientRef.get()
        if state == .idle, existing == nil, endState == .idle { return }
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
        hooks = SessionHooks()
        latencyOneWayMs = nil
        latencySamples = 0
        state = endState
    }

    // MARK: - Reconcile state (manager-driven; gap G9)

    /// Mark the bound slot server-applied — called by the manager when a
    /// session PUT / per-slot PUT reports the slot live. Feeds the
    /// expected-bitmap belief (dish-linux `markSlotApplied`).
    func markSlotApplied() {
        if boundSlotId != nil { slotApplied = true }
    }

    /// Adopt a server epoch as "what we last applied" (PUT responses and
    /// benign reconcile drift both land here).
    func setLastAppliedEpoch(_ epoch: Int) {
        lastAppliedEpoch = epoch
    }

    /// Flip the reconcile single-flight guard: true when the manager's GET
    /// launches, false when it lands.
    func setReconcileInFlight(_ inFlight: Bool) {
        reconcileInFlight = inFlight
    }

    /// The desired set as reconcile-comparable slots — the GET-compare input
    /// (`DishCore.appliedMatchesDesired`).
    func desiredSlots() -> [DesiredSlot] {
        guard let descriptor = desiredDescriptor else { return [] }
        return [DesiredSlot(ctrlIdx: UInt8(truncatingIfNeeded: descriptor.ctrlIdx), type: descriptor.type)]
    }

    /// The slots we believe the server has APPLIED — the expected-bitmap
    /// input. Distinct from `desiredSlots()` while a converge is in flight
    /// (see `slotApplied`).
    private func appliedBeliefSlots() -> [DesiredSlot] {
        slotApplied ? desiredSlots() : []
    }

    // MARK: - Slot binding (REST-converged; no UDP registration)

    func attachSlot(
        _ slotId: String,
        controllerType: Int,
        hasMotion: Bool,
        hasLight: Bool
    ) {
        boundSlotId = slotId
        pendingControllerType = controllerType
        pendingHasMotion = hasMotion
        pendingHasLight = hasLight
        // Faltering is still a live session (missed acks below the death
        // threshold) — topology converges ride REST, which may well be
        // healthy while UDP acks are lossy. Mirrors dish-linux attachSlot.
        if state == .live || state == .faltering { onTopologyChanged?() }
    }

    func detachSlot() {
        if boundSlotId == nil { return }
        boundSlotId = nil
        // The belief updates immediately: the DELETE is fired by the manager
        // asynchronously, and a failed DELETE self-heals via the reconcile.
        slotApplied = false
        if state == .live || state == .faltering { onTopologyChanged?() }
    }

    /// Spinner state for the manager's in-flight slot converge (kept a
    /// manager call, not a self-toggle, so the published flag mirrors the
    /// REAL request lifetime).
    func setSlotSyncInFlight(_ inFlight: Bool) {
        isRegisteringController = inFlight
    }

    // MARK: - Hot path

    /// Called directly from the GameController callback thread on every
    /// button/axis change. The `clientRef` read is a single locked pointer
    /// load (~ns on uncontended `os_unfair_lock`) and `SatelliteClient`
    /// itself serialises the `sendto` through its own lock.
    nonisolated func sendReport(
        buttons: UInt16,
        lt: UInt8,
        rt: UInt8,
        lx: Int16,
        ly: Int16,
        rx: Int16,
        ry: Int16
    ) {
        guard let live = clientRef.get() else { return }
        live.sendReport(
            controllerIndex: Self.defaultCtrlIndex,
            buttons: buttons,
            lt: lt,
            rt: rt,
            lx: lx,
            ly: ly,
            rx: rx,
            ry: ry
        )
    }

    /// Forward an IMU sample. Same threading discipline as `sendReport`:
    /// called from the GameController callback thread, must be lock-free
    /// outside of the single `sendto` inside `SatelliteClient`.
    nonisolated func sendMotion(
        gyroX: Int16, gyroY: Int16, gyroZ: Int16,
        accelX: Int16, accelY: Int16, accelZ: Int16,
        timestampDeltaUs: UInt32
    ) {
        guard let live = clientRef.get() else { return }
        live.sendMotion(
            controllerIndex: Self.defaultCtrlIndex,
            gyroX: gyroX,
            gyroY: gyroY,
            gyroZ: gyroZ,
            accelX: accelX,
            accelY: accelY,
            accelZ: accelZ,
            timestampDeltaUs: timestampDeltaUs
        )
    }

    /// Forward a battery snapshot. Sent on connect and every 30 s by the
    /// `BatteryReporter` background timer plus on charging-state transitions.
    nonisolated func sendBattery(level: UInt8, status: BatteryStatus) {
        guard let live = clientRef.get() else { return }
        live.sendBattery(
            controllerIndex: Self.defaultCtrlIndex,
            level: level,
            status: status
        )
    }

    // `sendTouchpad` takes one argument per wire field — it is a thin
    // pass-through to `SatelliteClient.sendTouchpad`; a struct wrapper would
    // only add an indirection, so the parameter-count rule is suppressed as it
    // is there.
    // swiftlint:disable function_parameter_count

    /// Forward a touchpad sample. Same threading discipline as `sendReport` —
    /// called from a GameController touchpad callback thread.
    ///
    /// `fingerNId` is the monotonic per-finger tracking id resolved upstream
    /// by `GameControllerInput.pushTouchpad`; `eventTimeMs` is the
    /// sender-side sample uptime stamp the 16-byte protocol-1 payload carries
    /// at offset 12 (contract §0x000C).
    nonisolated func sendTouchpad(
        finger0Active: Bool, finger0Id: UInt8, finger0X: Int16, finger0Y: Int16,
        finger1Active: Bool, finger1Id: UInt8, finger1X: Int16, finger1Y: Int16,
        buttonPressed: Bool,
        eventTimeMs: UInt32
    ) {
        guard let live = clientRef.get() else { return }
        live.sendTouchpad(
            controllerIndex: Self.defaultCtrlIndex,
            finger0Active: finger0Active,
            finger0Id: finger0Id,
            finger0X: finger0X,
            finger0Y: finger0Y,
            finger1Active: finger1Active,
            finger1Id: finger1Id,
            finger1X: finger1X,
            finger1Y: finger1Y,
            buttonPressed: buttonPressed,
            eventTimeMs: eventTimeMs
        )
    }

    // swiftlint:enable function_parameter_count

    /// Install (or replace) the rumble handler. Called from the AppModel
    /// during composition; we cache it on the WifiConnection so that
    /// `markConnected` can re-install it on each fresh `SatelliteClient`
    /// instance after a reconnect.
    func setRumbleHandler(_ handler: @escaping (RumbleCommand) -> Void) {
        rumbleHandler = handler
        clientRef.get()?.onRumble = handler
    }

    /// Install (or replace) the light-bar handler — same cache-and-reapply
    /// pattern as `setRumbleHandler` so it survives a reconnect.
    func setLightbarHandler(_ handler: @escaping (LightbarCommand) -> Void) {
        lightbarHandler = handler
        clientRef.get()?.onLightbar = handler
    }

    /// Whether a rumble handler is installed. `internal` so the G19
    /// prune/re-add tests can observe `AppModel`'s install pass without a
    /// live client — same seam pattern as `capabilityWord`.
    var hasRumbleHandler: Bool {
        rumbleHandler != nil
    }

    /// Same observability seam for the light-bar return path.
    var hasLightbarHandler: Bool {
        lightbarHandler != nil
    }
}

/// Thread-safe holder for the live `SatelliteClient` reference. Writes from
/// the main actor, reads from the GC thread — guarded by `os_unfair_lock`.
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
