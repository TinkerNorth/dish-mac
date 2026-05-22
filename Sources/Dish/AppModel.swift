// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Combine
import Foundation

/// Top-level application state. Owns the network + input layers and stitches
/// them together the same way Android's `MainViewModel` + `MainActivity` do:
///
///   * mirrors `GameControllerInput.slots` into `ControllerSlot`s,
///   * cross-references `ConnectionHub.bindings` to populate each slot's
///     `boundConnectionId` / `boundStatus`,
///   * installs a `reportSender` on the input processor that routes each
///     gamepad report to the connection bound to that device id.
@MainActor
final class AppModel: ObservableObject {

    let store: ConnectionStore
    let wifi: WifiConnectionManager
    let hub: ConnectionHub
    let input: GameControllerInput
    let wake: ScreenWakeController
    /// User-facing feature toggles (motion / rumble / touchpad / light bar).
    /// `SettingsView` binds to this directly; the off-main hot paths read the
    /// thread-safe `gate` mirror instead.
    let settings: FeatureSettings

    @Published private(set) var slots: [ControllerSlot] = []
    @Published private(set) var connections: [ConnectionSummary] = []

    /// Thread-safe snapshot of `settings` for the GameController callback
    /// thread + `SatelliteClient` receive queue, which can't touch the
    /// `@MainActor` `FeatureSettings`. Kept in sync by `syncGate()`.
    private let gate = ForwardingGate()

    /// Set when the server asks us to re-pair with a PIN. Bound to a sheet.
    @Published var pairingTarget: DiscoveredServer?
    /// Transient error banner. Kept for the inline `ErrorBanner` strip on
    /// the sheets that still render it; the notification queue
    /// (`DishNotificationCenter`) is the additive replacement for any
    /// top-level error surface.
    @Published var errorMessage: String?

    /// Weak handle to the process-scoped `DishNotificationCenter` (injected
    /// from `DishApp` once the SwiftUI environment is up). Optional because
    /// `AppModel` is constructed before the SwiftUI scene exists; emitters
    /// call through `routeNotification(_:)` which no-ops if unbound.
    private weak var notifications: DishNotificationCenter?

    /// Thread-safe slotId → live `WifiConnection` table, read by the input
    /// processor's `reportSender` from the GC callback thread and written
    /// from the main actor whenever bindings or the connection pool change.
    private let routingTable = RoutingTable()

    private var cancellables = Set<AnyCancellable>()

    init(
        inhibitor: DisplaySleepInhibitor? = nil
    ) {
        let store = ConnectionStore()
        let wifi = WifiConnectionManager(store: store)
        let hub = ConnectionHub(wifi: wifi, store: store)
        let input = GameControllerInput()
        let settings = FeatureSettings()
        self.store = store
        self.wifi = wifi
        self.hub = hub
        self.input = input
        self.settings = settings
        self.wake = ScreenWakeController(inhibitor: inhibitor ?? IOKitDisplaySleepInhibitor())

        // Seed the gate before any sender fires so the first packet already
        // respects the persisted toggles.
        gate.update(settings.flags)

        observe()
        installReportSender()
        installMotionSender()
        installBatterySender()
        installTouchpadSender()
        installRumbleHandlers()
        installLightbarHandlers()
        installMotionStatusObservers()
        // Auto-reconnect every remembered server on launch.
        wifi.autoReconnectAll()
    }

    /// Tracks which `WifiConnection` ids we've already attached the rumble
    /// handler to. WifiConnections live until they're forgotten, so this set
    /// only ever grows during a session — perfect for an "install once,
    /// re-install on reconnect via the WifiConnection" pattern.
    private var rumbleWiredConnections = Set<String>()
    /// Same idempotent-install bookkeeping for the light-bar return path.
    private var lightbarWiredConnections = Set<String>()
    /// Same idempotent-install bookkeeping for the motion-backend-status
    /// observer. Distinct subscription set so a future `forget(id:)` only
    /// has to tear down one closure per axis.
    private var motionStatusWiredConnections = Set<String>()
    /// Per-connection `motionBackendStatus` subscriptions — held here so
    /// they survive pool churn (we re-install once per id and tear down
    /// alongside the rumble / light bar wires when the connection is
    /// forgotten).
    private var motionStatusCancellables: [String: AnyCancellable] = [:]

    // MARK: - Wiring

    private func observe() {
        // Rebuild slot list whenever the GC layer reports a controller
        // add/remove, and whenever bindings or connections change.
        Publishers.CombineLatest3(input.$slots, hub.$connections, hub.$bindings)
            .sink { [weak self] gcSlots, conns, bindings in
                self?.rebuildSlots(gcSlots: gcSlots, conns: conns, bindings: bindings)
            }
            .store(in: &cancellables)

        // Keep the lock-protected routing table in sync with bindings + pool.
        Publishers.CombineLatest(hub.$bindings, wifi.$connections)
            .sink { [weak self] bindings, pool in
                guard let self else { return }
                var snapshot: [String: WifiConnection] = [:]
                for (slotId, cid) in bindings {
                    if let conn = pool[cid] { snapshot[slotId] = conn }
                }
                self.routingTable.set(snapshot)
            }
            .store(in: &cancellables)

        // Drive the display-sleep assertion off `bindings × hub.connections`.
        // The 0↔positive transitions inside ScreenWakeController acquire /
        // release the IOPMAssertion; intermediate same-count emissions are
        // no-ops so a noisy hub feed doesn't thrash IOKit.
        Publishers.CombineLatest(hub.$bindings, hub.$connections)
            .sink { [weak self] bindings, conns in
                guard let self else { return }
                let states = Dictionary(uniqueKeysWithValues: conns.map { ($0.id, $0.live) })
                let count = ScreenWakeController.streamingCount(
                    bindings: bindings,
                    connectionStates: states
                )
                self.wake.update(streamingSlotCount: count)
            }
            .store(in: &cancellables)

        // Make sure every newly-pooled WifiConnection has its rumble +
        // light bar handlers + motion-backend-status observer installed.
        // The pool only grows during a session — `register` adds entries,
        // `forget` removes — so we re-walk it on each pool change.
        wifi.$connections
            .sink { [weak self] _ in
                self?.installRumbleHandlers()
                self?.installLightbarHandlers()
                self?.installMotionStatusObservers()
            }
            .store(in: &cancellables)

        // Mirror every `FeatureSettings` change into the thread-safe gate
        // and reconcile each live connection's advertised caps against the
        // post-toggle truth (the motion bit is the only one currently
        // wired through `MSG_CONTROLLER_CAPS_UPDATE`; the rumble / touchpad
        // / lightbar gates live on the dish's own send path and don't
        // affect what the receiver expects to receive). `objectWillChange`
        // fires *before* the property mutates, so we hop one runloop tick
        // — same deferral `ConnectionHub` uses for its per-connection
        // `objectWillChange` subscriptions.
        settings.objectWillChange
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.gate.update(self.settings.flags)
                    self.refreshAllAdvertisedCaps()
                }
            }
            .store(in: &cancellables)

        // Surface pairing + error events to the UI. Errors are routed
        // through the notification queue (the additive replacement for
        // the single inline ErrorBanner) and also mirrored into
        // `errorMessage` so existing sheets that still embed an
        // `ErrorBanner` keep working unchanged.
        wifi.events
            .sink { [weak self] ev in
                guard let self else { return }
                switch ev {
                case let .pairingRequired(server): self.pairingTarget = server
                case let .error(msg):
                    self.errorMessage = msg
                    // Keyed on a stable string so multiple back-to-back
                    // failures collapse into one banner rather than
                    // stacking the same message six times.
                    self.notifications?.error(
                        title: msg,
                        key: "wifi.error"
                    )
                }
            }
            .store(in: &cancellables)
    }

    /// Wire the SwiftUI-owned notification center back into the model so
    /// `wifi.events` failures + future emit sites can post banners. Called
    /// from `DishApp.onAppear`. Idempotent: re-binding a fresh center on a
    /// scene rebuild simply replaces the prior weak reference.
    func bindNotifications(_ center: DishNotificationCenter) {
        self.notifications = center
    }

    private func rebuildSlots(
        gcSlots: [GameControllerInput.Slot],
        conns: [ConnectionSummary],
        bindings: [String: String]
    ) {
        var next: [ControllerSlot] = []
        for gc in gcSlots {
            next.append(ControllerSlot(
                id: gc.id,
                name: gc.name,
                capabilities: gc.capabilities,
                battery: gc.battery
            ))
        }
        // Evict bindings whose slot disappeared (e.g., controller unplugged).
        let known = Set(next.map(\.id))
        for (slotId, _) in bindings where !known.contains(slotId) {
            hub.unbind(slotId: slotId)
        }
        // Fill boundConnectionId / boundStatus.
        for idx in next.indices {
            if let cid = bindings[next[idx].id] {
                next[idx].boundConnectionId = cid
                next[idx].boundStatus = conns.first { $0.id == cid }
            }
        }
        self.slots = next
        self.connections = conns
    }

    /// Install the rumble handler on every WifiConnection in the pool that
    /// doesn't already have one. The handler walks the current bindings
    /// (slotId → connectionId), finds the slot bound to *this* connection,
    /// and forwards the `MSG_RUMBLE` payload to `GameControllerInput` for that
    /// slot id (== device id, by construction in `rebuildSlots`).
    ///
    /// The handler drives vibration only — the light bar is a separate return
    /// path (`installLightbarHandlers`). Vibration is gated on the Rumble
    /// toggle.
    private func installRumbleHandlers() {
        let input = self.input
        let hub = self.hub
        let gate = self.gate
        for (id, conn) in wifi.connections {
            if rumbleWiredConnections.contains(id) { continue }
            rumbleWiredConnections.insert(id)
            conn.setRumbleHandler { rm in
                // Rumble toggle off → drop without the main-actor hop.
                guard ReturnPathRouting.shouldVibrate(flags: gate.snapshot()) else { return }
                Task { @MainActor in
                    var deviceId: String?
                    for (slotId, cid) in hub.bindings where cid == id {
                        deviceId = slotId
                        break
                    }
                    guard let deviceId else { return }
                    input.applyRumble(
                        deviceId: deviceId,
                        strongMagnitude: rm.strongMagnitude,
                        weakMagnitude: rm.weakMagnitude,
                        durationMs: rm.durationMs
                    )
                }
            }
        }
    }

    /// Wire the input processor so every gamepad report from device `id`
    /// is routed to the connection bound to the slot with that same id.
    /// Runs on the GameController callback thread — a single locked dict
    /// read per event, no main-actor hop.
    private func installReportSender() {
        let table = routingTable
        input.processor.reportSender = { deviceId, wButtons, lt, rt, lx, ly, rx, ry in
            guard let conn = table.get(deviceId) else { return }
            conn.sendReport(
                buttons: wButtons,
                lt: lt,
                rt: rt,
                lx: lx,
                ly: ly,
                rx: rx,
                ry: ry
            )
        }
    }

    /// Wire motion samples through the same routing table the gamepad path
    /// uses — same threading discipline, single locked dict read, no hop.
    /// Gated on the user's motion toggle (`gate.snapshot().motion`).
    private func installMotionSender() {
        let table = routingTable
        let gate = self.gate
        input.processor.motionSender = { deviceId, gx, gy, gz, ax, ay, az, dt in
            guard gate.snapshot().motion else { return }
            guard let conn = table.get(deviceId) else { return }
            conn.sendMotion(
                gyroX: gx,
                gyroY: gy,
                gyroZ: gz,
                accelX: ax,
                accelY: ay,
                accelZ: az,
                timestampDeltaUs: dt
            )
        }
    }

    /// Wire touchpad samples through the routing table, gated on the user's
    /// touchpad toggle. Same callback shape + threading as `motionSender`.
    private func installTouchpadSender() {
        let table = routingTable
        let gate = self.gate
        input.processor.touchpadSender = { deviceId, f0a, f0id, f0x, f0y, f1a, f1id, f1x, f1y, btn in
            guard gate.snapshot().touchpad else { return }
            guard let conn = table.get(deviceId) else { return }
            conn.sendTouchpad(
                finger0Active: f0a,
                finger0Id: f0id,
                finger0X: f0x,
                finger0Y: f0y,
                finger1Active: f1a,
                finger1Id: f1id,
                finger1X: f1x,
                finger1Y: f1y,
                buttonPressed: btn
            )
        }
    }

    /// Install the light-bar handler on every pooled WifiConnection — same
    /// install-once / re-walk-on-pool-change pattern as `installRumbleHandlers`.
    /// The handler resolves the bound slot and applies the host-game colour to
    /// that controller, unless the user set the light bar to "Off".
    private func installLightbarHandlers() {
        let input = self.input
        let hub = self.hub
        let gate = self.gate
        for (id, conn) in wifi.connections {
            if lightbarWiredConnections.contains(id) { continue }
            lightbarWiredConnections.insert(id)
            conn.setLightbarHandler { lm in
                // Gated on the Light bar setting.
                guard ReturnPathRouting.shouldApply(lightbar: lm, flags: gate.snapshot()) else { return }
                Task { @MainActor in
                    var deviceId: String?
                    for (slotId, cid) in hub.bindings where cid == id {
                        deviceId = slotId
                        break
                    }
                    guard let deviceId else { return }
                    input.applyLightbar(deviceId: deviceId, r: lm.r, g: lm.g, b: lm.b)
                }
            }
        }
    }

    /// Subscribe to each pooled WifiConnection's `motionBackendStatus` and
    /// surface a warning notification when the receiver tells us motion
    /// bytes won't actually reach the virtual gamepad's IMU surface. Today
    /// the only signal we can act on is `backendOk == false` — the
    /// receiver's kernel rejected the per-serial IMU sink at plug-in time
    /// (Linux uinput with a too-old kernel, missing `/dev/uinput`
    /// permission, etc.). A satellite that simply doesn't support motion
    /// for the chosen controller type (`sinkSupportedForType == false`) is
    /// the normal Xbox / generic-HID case and not worth a notification.
    ///
    /// `nil` means either no registration has happened yet, or the
    /// satellite is pre-extension (4-byte legacy ACK with no motion byte) —
    /// in both cases the UI falls back to local hardware truth rather than
    /// surfacing a misleading warning. `dish-mac` talking to a `macOS`
    /// satellite never lights this up because the satellite returns
    /// `ACK_ERR_BACKEND_UNAVAIL` long before computing motion flags — the
    /// notification surface is meaningful only against Linux / Windows
    /// receivers.
    ///
    /// Notification key includes the connection id so two different broken
    /// satellites stack as two banners rather than collapsing into one,
    /// and a re-bind on the same connection re-keys the same banner so it
    /// doesn't pile up over time.
    private func installMotionStatusObservers() {
        for (id, conn) in wifi.connections {
            if motionStatusWiredConnections.contains(id) { continue }
            motionStatusWiredConnections.insert(id)
            let cancellable = conn.$motionBackendStatus
                .removeDuplicates()
                .sink { [weak self] status in
                    guard let self else { return }
                    guard let status, !status.backendOk, status.sinkSupportedForType else {
                        // Either pre-extension satellite, broken type
                        // (Xbox on Linux — not a failure), or motion is
                        // actually fine. Nothing to surface.
                        return
                    }
                    let label = self.wifi.connections[id]?.server.name ?? id
                    self.notifications?.warn(
                        title: "Server can't deliver motion",
                        body: "\(label) supports motion for this controller, but the "
                            + "receiver couldn't create the IMU sink (kernel rejected the "
                            + "per-serial motion node). Gyro forwarding will land nowhere.",
                        key: "motion.backend.\(id)"
                    )
                }
            motionStatusCancellables[id] = cancellable
        }
    }

    /// Push a fresh capability word to every live connection so the
    /// receiver's `Controller::caps` matches the post-toggle truth. Called
    /// from the `FeatureSettings` observer after the toggle has settled.
    ///
    /// Idempotent: a connection whose toggle didn't change (or whose
    /// `lastAdvertisedCaps` already matches) sends zero wire packets,
    /// thanks to `WifiConnection.refreshCapsIfChanged`'s internal de-dup
    /// — so an unrelated toggle (rumble / touchpad / lightbar) re-emitting
    /// `objectWillChange` doesn't burn a UDP packet per tick. Mirrors
    /// `dish-android`'s `SatelliteConnection.refreshCapsIfChanged`
    /// reconciliation step in `SatelliteConnectionManager`'s composer
    /// subscription.
    private func refreshAllAdvertisedCaps() {
        let motionEnabled = settings.motionEnabled
        for (_, conn) in wifi.connections {
            conn.refreshCapsIfChanged(motionEnabled: motionEnabled)
        }
    }

    /// Wire battery snapshots. This callback runs on the main actor (the
    /// GCDeviceBattery polling timer is scheduled on `.main`), so the lookup
    /// is safe but the send itself is `nonisolated` so the lock-free hot path
    /// shape is preserved.
    private func installBatterySender() {
        let table = routingTable
        input.processor.batterySender = { deviceId, level, statusRaw in
            guard let conn = table.get(deviceId) else { return }
            // Coerce the raw byte back to the enum at the boundary; default
            // to .unknown if a future firmware ever surfaces a state we
            // haven't seen, so we never crash on malformed input.
            let status = SatelliteClient.BatteryStatus(rawValue: statusRaw) ?? .unknown
            conn.sendBattery(level: level, status: status)
        }
    }

    // MARK: - UI actions

    func disconnect(_ id: String) {
        wifi.disconnect(id: id)
    }

    func connect(_ server: DiscoveredServer) {
        wifi.connect(to: server)
    }

    func forget(_ id: String) {
        wifi.forget(id: id)
    }

    func startScan() {
        wifi.startDiscovery()
    }

    func pairWithPin(_ server: DiscoveredServer, pin: String) {
        wifi.pairWithPin(server, pin: pin)
    }

    func bind(slotId: String, connectionId: String) {
        // Resolve whether the bound controller has an IMU / an RGB light bar
        // from its detected capabilities, so `WifiConnection` can advertise
        // CAP_MOTION / CAP_LIGHTBAR in MSG_CONTROLLER_ADD. Both default to
        // false for an unknown slot id.
        // `motionEnabled` is the user's live toggle — folded into the
        // CAP_MOTION advertisement so we never tell the receiver we're
        // about to stream motion while the toggle is off (the receiver
        // would otherwise wait for samples that never arrive). When the
        // toggle flips after this bind, `installCapsRefresher` pushes a
        // `MSG_CONTROLLER_CAPS_UPDATE` (0x000E) to keep the receiver in
        // sync without unplugging the virtual controller.
        let caps = slots.first { $0.id == slotId }?.capabilities
        hub.bind(
            slotId: slotId,
            connectionId: connectionId,
            hasMotion: caps?.hasMotion ?? false,
            hasLight: caps?.hasLightbar ?? false,
            motionEnabled: settings.motionEnabled
        )
    }

    func unbind(slotId: String) {
        hub.unbind(slotId: slotId)
    }
}

/// Thread-safe slotId → live-connection dispatch table used by the input
/// processor's hot path.
final class RoutingTable: @unchecked Sendable {
    private var map: [String: WifiConnection] = [:]
    private var lock = os_unfair_lock_s()
    func get(_ slotId: String) -> WifiConnection? {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return map[slotId]
    }

    func set(_ snapshot: [String: WifiConnection]) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        map = snapshot
    }
}
