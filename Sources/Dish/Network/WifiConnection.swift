// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Combine
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
///   reaching it requires the native side to expose the consecutive-missed
///   count separately from the binary alive-poll boolean. Today the
///   alive-poll flips `live` → `stale` directly when misses hit the threshold.
/// - `stale` — heartbeats stopped arriving but we still hold a shared key.
///   The manager attempts a silent re-handshake (no user-visible error)
///   using the saved key; only if that fails does the chip fall back to a
///   resting `.saved` / `.ready` and surface a banner if the retry was
///   user-initiated. Ports the `RETRY_AFTER_DEATH` path from
///   `dish-android/source/connection/SatelliteConnectionManager.kt`.
enum SessionState { case idle, linking, live, faltering, stale }

/// A single live or potential WiFi session to one Satellite server. Owns a
/// `SatelliteClient` instance (the native UDP session) once `live`.
/// Mirrors `WifiConnection.kt`.
@MainActor
final class WifiConnection: ObservableObject, Identifiable {

    let id: String
    @Published private(set) var server: DiscoveredServer
    @Published private(set) var state: SessionState = .idle
    @Published private(set) var boundSlotId: String?
    /// True while a `MSG_CONTROLLER_ADD` is awaiting `MSG_CONTROLLER_ACK`.
    /// The dashboard observes this to show a spinner.
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

    /// Human-readable controller-registration errors (timeout or server
    /// rejection codes). Listened to by `WifiConnectionManager` and forwarded
    /// into the global event stream so the UI can surface them inline.
    let errorMessages = PassthroughSubject<String, Never>()
    /// Emitted with the slot id when registration is rejected/times out so
    /// `ConnectionHub` can roll back the local binding.
    let slotRegistrationFailed = PassthroughSubject<String, Never>()

    private var aliveTask: Task<Void, Never>?
    private var registrationTask: Task<Void, Never>?
    private var controllerAdded = false
    private var pendingControllerType = 0
    /// Whether the bound physical controller exposes an addressable RGB light
    /// (`GCController.light != nil`). Captured at bind time and folded into the
    /// `MSG_CONTROLLER_ADD` capability word as `CAP_LIGHTBAR`.
    private var pendingHasLight = false
    /// Whether the bound physical controller exposes a `GCMotion` IMU surface.
    /// Captured at bind time and folded into the `MSG_CONTROLLER_ADD`
    /// capability word as `CAP_MOTION` — a pad with no IMU must not advertise
    /// that it streams motion.
    private var pendingHasMotion = false
    /// Snapshot of the user's `FeatureSettings.motionEnabled` toggle at
    /// bind time. The honest CAP_MOTION advertisement is
    /// `hasMotion && motionEnabled`: a pad with an IMU whose owner has
    /// switched motion forwarding off must not advertise that it streams
    /// motion (the receiver would otherwise wait for samples that never
    /// arrive). When the toggle flips after registration,
    /// `refreshCapsIfChanged(motionEnabled:)` pushes a
    /// `MSG_CONTROLLER_CAPS_UPDATE` so the receiver's cap word matches.
    private var pendingMotionEnabled = true
    /// Most recent capability word the dish has told the satellite about
    /// for this connection — either via the original `MSG_CONTROLLER_ADD`
    /// or a subsequent `MSG_CONTROLLER_CAPS_UPDATE` (0x000E).
    /// `refreshCapsIfChanged(motionEnabled:)` uses this to de-dup
    /// composer-style emissions that don't actually change the wire word,
    /// so a churning settings sink (e.g. an unrelated toggle re-emitting
    /// `objectWillChange`) doesn't burn a UDP packet per tick. `nil` means
    /// "no registration has happened yet" — there's nothing to refresh
    /// against; the next `registerController` will pick up the fresh caps.
    /// Mirrors `SlotBinding.lastAdvertisedCaps` in `dish-android`.
    @Published private(set) var lastAdvertisedCaps: UInt16?
    /// Receiver-side motion-backend truth from the optional 5th byte of the
    /// last `MSG_CONTROLLER_ACK`. `nil` means either no registration has
    /// happened yet, or the satellite is a pre-extension build that only
    /// sent the legacy 4-byte ACK payload — both collapse to "unknown" so
    /// callers fall back to local hardware truth rather than reading the
    /// missing byte as "backend broken." Surfaced to the UI / notification
    /// layer so a user with motion on a controller whose receiver kernel
    /// rejected the IMU node sees a real reason rather than a cheerful
    /// "Motion: on" pill while motion bytes silently land nowhere.
    @Published private(set) var motionBackendStatus: SatelliteClient.MotionBackendStatus?

    /// Set once during composition; re-applied to each fresh `SatelliteClient`
    /// in `markConnected` so we don't lose rumble across reconnects. The
    /// closure runs on the SatelliteClient's receive-loop dispatch queue.
    private var rumbleHandler: ((SatelliteClient.RumbleMessage) -> Void)?
    /// Same pattern for the decoupled `MSG_LIGHTBAR` return path.
    private var lightbarHandler: ((SatelliteClient.LightbarMessage) -> Void)?

    private nonisolated static let defaultCtrlIndex = 0
    /// `MSG_CONTROLLER_ADD` capability word, fixed bits: analog triggers
    /// (`CAP_ANALOG_TRIGGERS` 0x0001) | rumble (`CAP_RUMBLE` 0x0002). Every
    /// macOS-bridged extended gamepad has analog triggers and accepts the
    /// rumble return path, so these two are always advertised. `CAP_MOTION`
    /// and `CAP_LIGHTBAR` are per-controller — see `capabilityWord`.
    nonisolated static let defaultCaps: UInt16 = 0x0003
    /// `CAP_MOTION` — set per-controller when the bound pad exposes a
    /// `GCMotion` IMU. Matches `CAP_MOTION` in `satellite/src/core/types.h`.
    /// A pad with no IMU must not advertise it streams `MSG_MOTION`.
    nonisolated static let capMotion: UInt16 = 0x0004
    /// `CAP_LIGHTBAR` — set per-controller when the bound pad has an
    /// addressable RGB LED (`GCController.light != nil`). Matches
    /// `satellite/src/core/types.h` and is decoded identically by every
    /// dish client.
    nonisolated static let capLightbar: UInt16 = 0x0008
    private nonisolated static let ackWaitAttempts = 20
    private nonisolated static let ackWaitIntervalMs: UInt64 = 100

    /// The `MSG_CONTROLLER_ADD` capability word for a controller: the fixed
    /// `defaultCaps` bits with `CAP_LIGHTBAR` OR'd in only when the bound
    /// physical controller actually exposes an addressable RGB light, and
    /// `CAP_MOTION` OR'd in only when the controller exposes an IMU **and**
    /// the user's motion-forwarding toggle is on. The toggle is part of the
    /// derivation because the dish that advertises CAP_MOTION but never
    /// emits `MSG_MOTION` is dishonest about what it's willing to stream —
    /// the receiver would wait for samples that never arrive. Mirrors
    /// `MotionCapabilityComposer.toCapBits` on `dish-android`.
    ///
    /// `internal` (not `private`) so the per-controller cap computation can
    /// be unit-tested without standing up a live session — the same seam
    /// pattern as `SatelliteClient.parseRumblePayload`.
    nonisolated static func capabilityWord(
        hasMotion: Bool,
        hasLight: Bool,
        motionEnabled: Bool = true
    ) -> UInt16 {
        var word = defaultCaps
        if hasMotion, motionEnabled { word |= capMotion }
        if hasLight { word |= capLightbar }
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

    /// Promote to `live`. Starts the ACK receive loop + heartbeat, and if a
    /// slot was already bound it kicks the server-side controller handshake.
    func markConnected(
        client: SatelliteClient,
        connectionId: String,
        onDead: @escaping () -> Void
    ) {
        guard state == .linking else { return }
        clientRef.set(client)
        self.connectionId = connectionId
        state = .live
        client.resetControllerAck()
        client.rumbleHandler = rumbleHandler
        client.lightbarHandler = lightbarHandler
        client.startReceiveLoop()
        client.startHeartbeat()

        aliveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self else { return }
                if self.clientRef.get()?.connectionAlive.get() == false {
                    // TODO(faltering): when the native layer exposes the
                    // consecutive-missed-heartbeat count separately from the
                    // binary alive-poll, flip state = .faltering as misses
                    // cross 1 and only fall through to onDead() at the death
                    // threshold. Today the alive-poll is a hard boolean.
                    //
                    // Heartbeats stopped: flip the wire-level state to .stale
                    // *before* invoking onDead so the manager's silent-retry
                    // path can tell "we were alive a moment ago" from a fresh
                    // user-initiated reconnect. The chip stays on "Online" /
                    // "Unsteady" through the silent retry — only if the retry
                    // can't restore the session does it fall back to .saved /
                    // .ready (and only emit a user-visible banner if the
                    // attempt was user-initiated).
                    await MainActor.run {
                        if self.state == .live { self.state = .stale }
                        onDead()
                    }
                    return
                }
            }
        }
        if boundSlotId != nil, !controllerAdded {
            registrationTask = Task { [weak self] in
                guard let self else { return }
                await self.registerController(type: self.pendingControllerType)
            }
        }
    }

    func markDisconnected() {
        let existing = clientRef.get()
        if state == .idle, existing == nil { return }
        aliveTask?.cancel()
        aliveTask = nil
        registrationTask?.cancel()
        registrationTask = nil
        isRegisteringController = false
        existing?.stopHeartbeat()
        existing?.closeSocket()
        clientRef.set(nil)
        connectionId = nil
        controllerAdded = false
        // Receiver-side facts (advertised caps + motion-backend status) are
        // bound to the live session; a fresh session must compute them
        // anew rather than reading the previous handshake's truth.
        lastAdvertisedCaps = nil
        motionBackendStatus = nil
        state = .idle
    }

    // MARK: - Slot binding

    func attachSlot(
        _ slotId: String,
        controllerType: Int,
        hasMotion: Bool,
        hasLight: Bool,
        motionEnabled: Bool
    ) async {
        boundSlotId = slotId
        pendingControllerType = controllerType
        pendingHasMotion = hasMotion
        pendingHasLight = hasLight
        pendingMotionEnabled = motionEnabled
        if state == .live, !controllerAdded {
            await registerController(type: controllerType)
        }
    }

    func detachSlot() {
        if boundSlotId == nil { return }
        boundSlotId = nil
        registrationTask?.cancel()
        registrationTask = nil
        isRegisteringController = false
        if controllerAdded, let live = client {
            live.controllerRemove(index: Self.defaultCtrlIndex)
        }
        controllerAdded = false
        // Drop the cached per-slot caps + receiver-side motion truth — the
        // next attach for this slot writes a fresh status, and leaving
        // stale data here would mislead the notification surface in the
        // meantime. Mirrors `dish-android`'s
        // `SatelliteMotionBackendStatusStore.clear(connectionId, slotId)`
        // call from `SatelliteConnection.detachSlot`.
        lastAdvertisedCaps = nil
        motionBackendStatus = nil
    }

    private func registerController(type: Int) async {
        guard let live = clientRef.get() else { return }
        let slotId = boundSlotId
        live.resetControllerAck()
        // Capability word is per-controller: the fixed analog/rumble bits,
        // plus CAP_LIGHTBAR only when the bound pad has an addressable RGB
        // light, and CAP_MOTION only when the pad has an IMU **and** the
        // user's motion-forwarding toggle is on. Advertising CAP_MOTION
        // while motion is toggled off would be dishonest — the receiver
        // would wait for samples that never arrive — so the cap word
        // tracks the dish's actual willingness to stream.
        let caps = Self.capabilityWord(
            hasMotion: pendingHasMotion,
            hasLight: pendingHasLight,
            motionEnabled: pendingMotionEnabled
        )
        live.controllerAdd(
            index: Self.defaultCtrlIndex,
            capabilities: caps
        )
        isRegisteringController = true
        defer { isRegisteringController = false }

        var attempts = 0
        while attempts < Self.ackWaitAttempts, live.lastControllerAck == -1 {
            try? await Task.sleep(nanoseconds: Self.ackWaitIntervalMs * 1_000_000)
            attempts += 1
        }
        let ack = live.lastControllerAck
        if ack == -1 {
            errorMessages.send("Server did not acknowledge controller add (timeout)")
            if let slotId { slotRegistrationFailed.send(slotId) }
            return
        }
        let result = UInt8(ack & 0xFF)
        if result == 0x00 /* ACK_OK */ {
            live.sendControllerType(index: Self.defaultCtrlIndex, type: type)
            controllerAdded = true
            // Record what we just advertised so a later
            // `refreshCapsIfChanged(motionEnabled:)` can de-dup
            // unchanged-toggle emissions. Must happen after the ACK has
            // landed (the receiver's `Controller::caps` now matches this
            // word); writing it before would let a toggle flip *during*
            // the ACK wait sneak in a duplicate update.
            lastAdvertisedCaps = caps
            // Capture the optional motion-flags byte the satellite
            // appended to the ACK. A pre-extension satellite leaves
            // `lastControllerAckMotionFlags == -1` here — leave
            // `motionBackendStatus = nil` so the UI falls back to local
            // hardware truth rather than treating absent flags as
            // "permanently broken." A `dish-mac` talking to a `macOS`
            // satellite never reaches this branch (the satellite returns
            // `ACK_ERR_BACKEND_UNAVAIL` before computing motion flags);
            // that's expected.
            let flagsRaw = live.lastControllerAckMotionFlags
            if flagsRaw >= 0 {
                motionBackendStatus = SatelliteClient.MotionBackendStatus.fromFlags(
                    UInt8(truncatingIfNeeded: flagsRaw)
                )
            } else {
                motionBackendStatus = nil
            }
        } else {
            errorMessages.send(Self.controllerAckErrorMessage(result))
            if let slotId { slotRegistrationFailed.send(slotId) }
        }
    }

    /// Push a fresh capability word to the satellite if the user's motion
    /// toggle has flipped since registration. The new caps are computed
    /// from the same `hasMotion` / `hasLight` snapshot captured at bind
    /// time, with the runtime `motionEnabled` argument folded in — so the
    /// receiver's `Controller::caps` always matches what the dish is
    /// willing to stream right now.
    ///
    /// Idempotent: calling with the same `motionEnabled` value twice
    /// results in zero wire packets because `lastAdvertisedCaps` already
    /// equals the recomputed word. The pendingMotionEnabled mirror is
    /// updated so a later re-registration (e.g. after a stale-session
    /// reconnect) picks up the post-toggle truth via the same
    /// `capabilityWord` derivation.
    ///
    /// Wire shape: `MSG_CONTROLLER_CAPS_UPDATE` (0x000E), payload
    /// `ctrlIdx(1) + caps(2 BE)` — see `SatelliteClient.controllerCapsUpdate`.
    /// A pre-extension satellite drops the packet silently in
    /// `inner_dispatch.cpp`; the dish-side `motionEnabled` gate on the
    /// motion sender is the load-bearing correctness path, so the wire
    /// update is purely a receiver-dashboard freshener.
    func refreshCapsIfChanged(motionEnabled: Bool) {
        pendingMotionEnabled = motionEnabled
        guard controllerAdded, let live = clientRef.get() else { return }
        let newCaps = Self.capabilityWord(
            hasMotion: pendingHasMotion,
            hasLight: pendingHasLight,
            motionEnabled: motionEnabled
        )
        if lastAdvertisedCaps == newCaps { return }
        live.controllerCapsUpdate(
            index: Self.defaultCtrlIndex,
            capabilities: newCaps
        )
        lastAdvertisedCaps = newCaps
    }

    /// Maps the `MSG_CONTROLLER_ACK` result byte to a human-readable string.
    /// Codes match `satellite/src/core/types.h` and are kept identical to
    /// `dish-linux` and `dish-android` so users see the same text on any client.
    private nonisolated static func controllerAckErrorMessage(_ result: UInt8) -> String {
        switch result {
        case 0x01:
            "Server has no virtual gamepad backend — controller cannot be created"
        case 0x02:
            "Server has no free controller slots"
        case 0x03:
            "Controller already added on the server"
        case 0x04:
            "Controller not found on the server"
        case 0x05:
            "Server failed to plug in the virtual controller"
        default:
            "Server rejected controller add (code \(result))"
        }
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
    nonisolated func sendBattery(level: UInt8, status: SatelliteClient.BatteryStatus) {
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
    /// `fingerNId` is the monotonic per-finger tracking id resolved upstream by
    /// `GameControllerInput.pushTouchpad` — bumped on each fresh contact, the
    /// id the protocol's §0x000C expects (it used to be hardcoded 0 / 1).
    nonisolated func sendTouchpad(
        finger0Active: Bool, finger0Id: UInt8, finger0X: Int16, finger0Y: Int16,
        finger1Active: Bool, finger1Id: UInt8, finger1X: Int16, finger1Y: Int16,
        buttonPressed: Bool
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
            buttonPressed: buttonPressed
        )
    }

    // swiftlint:enable function_parameter_count

    /// Install (or replace) the rumble handler. Called from the AppModel
    /// during composition; we cache it on the WifiConnection so that
    /// `markConnected` can re-install it on each fresh `SatelliteClient`
    /// instance after a reconnect.
    func setRumbleHandler(_ handler: @escaping (SatelliteClient.RumbleMessage) -> Void) {
        rumbleHandler = handler
        clientRef.get()?.rumbleHandler = handler
    }

    /// Install (or replace) the light-bar handler — same cache-and-reapply
    /// pattern as `setRumbleHandler` so it survives a reconnect.
    func setLightbarHandler(_ handler: @escaping (SatelliteClient.LightbarMessage) -> Void) {
        lightbarHandler = handler
        clientRef.get()?.lightbarHandler = handler
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
