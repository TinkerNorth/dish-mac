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
/// - `faltering` — `live`, but the heartbeat-miss counter is non-zero and
///   below the death threshold. UI chip: "Unsteady". **Not yet entered** —
///   wiring the `missedAcks` count into the alive tick is W3-A (gap G15).
///   Today the alive-poll flips `live` → `stale` directly at the threshold.
/// - `stale` — heartbeats stopped arriving but we still hold a shared key.
///   The manager attempts a silent re-handshake (no user-visible error)
///   using the saved key; only if that fails does the chip fall back to a
///   resting `.saved` / `.ready` and surface a banner if the retry was
///   user-initiated. Ports the `RETRY_AFTER_DEATH` path from
///   `dish-android/source/connection/SatelliteConnectionManager.kt`.
enum SessionState { case idle, linking, live, faltering, stale }

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
    /// MSG_SESSION_CLOSE parse. Reason-specific teardown policy
    /// (`closeActionForReason`) is wired by W3-A; the alive tick already
    /// reaps the dead session either way (gap G10 parse side).
    var onSessionClose: ((CloseReason) -> Void)?

    /// Latest enriched heartbeat ack, refreshed by the 1 Hz alive tick while
    /// `live` — the reconcile driver's (W3-A) polled input (gap G9).
    private(set) var lastHeartbeatAck: HeartbeatAck?

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

    init(id: String, server: DiscoveredServer) {
        self.id = id
        self.server = server
    }

    static func idFor(_ server: DiscoveredServer) -> String {
        server.id
    }

    func updateServer(_ server: DiscoveredServer) {
        self.server = server
    }

    func markConnecting() {
        if state == .live { return }
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
    /// alive tick (liveness, enriched-ack snapshot poll, re-key poll).
    func markConnected(
        client: SatelliteClient,
        connectionId: String,
        onDead: @escaping () -> Void
    ) {
        guard state == .linking else { return }
        clientRef.set(client)
        self.connectionId = connectionId
        state = .live
        lastHeartbeatAck = nil
        rekeyRequested = false
        client.onRumble = rumbleHandler
        client.onLightbar = lightbarHandler
        client.onSessionClose = { [weak self] reason in
            // Receive-queue → main-actor hop. The client already dropped
            // `connectionAlive`, so the alive tick below reaps the session
            // within a tick; this forwards the parsed WHY.
            Task { @MainActor [weak self] in
                self?.onSessionClose?(reason)
            }
        }
        client.startReceiveLoop()
        client.startHeartbeat()

        aliveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self else { return }
                guard let live = self.clientRef.get() else { return }
                self.tickSnapshotsAndRekey(live)
                if !live.connectionAlive.get() {
                    // TODO(faltering): W3-A flips state = .faltering as
                    // `missedAcks` crosses the not-responding threshold and
                    // only falls through to onDead() at the death threshold
                    // (gap G15).
                    //
                    // Heartbeats stopped (or an authenticated close-notify
                    // landed): flip the wire-level state to .stale *before*
                    // invoking onDead so the manager's silent-retry path can
                    // tell "we were alive a moment ago" from a fresh
                    // user-initiated reconnect.
                    if self.state == .live { self.state = .stale }
                    onDead()
                    return
                }
            }
        }
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
        let existing = clientRef.get()
        if state == .idle, existing == nil { return }
        aliveTask?.cancel()
        aliveTask = nil
        isRegisteringController = false
        existing?.closeSocket()
        clientRef.set(nil)
        connectionId = nil
        lastHeartbeatAck = nil
        state = .idle
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
        if state == .live { onTopologyChanged?() }
    }

    func detachSlot() {
        if boundSlotId == nil { return }
        boundSlotId = nil
        if state == .live { onTopologyChanged?() }
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
