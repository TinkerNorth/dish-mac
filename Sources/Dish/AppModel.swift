// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import AppKit
import Combine
import DishCore
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
        inhibitor: DisplaySleepInhibitor? = nil,
        store: ConnectionStore = ConnectionStore(),
        notificationCenter: NotificationCenter = .default,
        workspaceNotificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter
    ) {
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
        installFocusLossRelease(notificationCenter)
        installSleepWakeHandling(workspaceNotificationCenter)
        installReportSender()
        installMotionSender()
        installBatterySender()
        installTouchpadSender()
        installRumbleHandlers()
        installLightbarHandlers()
        // Auto-reconnect every remembered server on launch.
        wifi.autoReconnectAll()
    }

    /// Release-all on focus loss (gap G19): when the app resigns active, the
    /// GameController callbacks stop delivering to us, so whatever buttons
    /// were down at the hand-off would stay held server-side — a stuck
    /// W-in-a-game while the player alt-tabs. Zero every known device and
    /// send the release reports through the normal routing path. The center
    /// is injectable so tests can post the notification without an
    /// NSApplication. Mirrors the sibling clients' focus-loss panic release.
    private func installFocusLossRelease(_ center: NotificationCenter) {
        center.publisher(for: NSApplication.didResignActiveNotification)
            .sink { [weak self] _ in
                self?.input.processor.zeroAndSendAll()
            }
            .store(in: &cancellables)
    }

    /// Sleep/wake (NSWorkspace notifications — a forced lid-close may never
    /// deliver `didResignActive`, so a held button would stay latched on the
    /// virtual pad until heartbeat death): on sleep run the same release-all
    /// path as focus loss; on wake reconnect NOW instead of waiting out the
    /// backoff curve (the socket may be dead, the IP may have moved).
    /// dish-android holds a PARTIAL_WAKE_LOCK for the same class of problem.
    private func installSleepWakeHandling(_ center: NotificationCenter) {
        center.publisher(for: NSWorkspace.willSleepNotification)
            .sink { [weak self] _ in
                self?.input.processor.zeroAndSendAll()
            }
            .store(in: &cancellables)
        center.publisher(for: NSWorkspace.didWakeNotification)
            .sink { [weak self] _ in
                self?.wifi.resumeAfterWake()
            }
            .store(in: &cancellables)
    }

    /// Tracks which `WifiConnection` ids we've already attached the rumble
    /// handler to ("install once, re-install on reconnect via the
    /// WifiConnection" pattern). Pruned to the live pool on every pool
    /// change (gap G19): a forgotten satellite that is later re-added gets a
    /// FRESH `WifiConnection` under the same id, and a stale membership here
    /// would skip the install — leaving the new session with no rumble
    /// return path.
    private var rumbleWiredConnections = Set<String>()
    /// Same install-once bookkeeping (and the same prune) for the light-bar
    /// return path.
    private var lightbarWiredConnections = Set<String>()

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

        // Make sure every newly-pooled WifiConnection has its rumble + light
        // bar handlers installed, and prune the wired-id bookkeeping for
        // entries `forget` removed. The walk uses the EMITTED pool — the
        // property itself is still pre-mutation while `@Published` delivers
        // (willSet), so re-reading `wifi.connections` here would miss the
        // entry that just registered until the following pool change.
        wifi.$connections
            .sink { [weak self] pool in
                guard let self else { return }
                self.pruneReturnPathWiring(to: pool)
                self.installRumbleHandlers(pool)
                self.installLightbarHandlers(pool)
            }
            .store(in: &cancellables)

        // Mirror every `FeatureSettings` change into the thread-safe gate.
        // The handler re-reads `settings.flags`, so delivery must wait for
        // the mutation to settle (see `afterMutationSettles`).
        settings.objectWillChange
            .afterMutationSettles()
            .sink { [weak self] _ in
                guard let self else { return }
                self.gate.update(self.settings.flags)
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

    /// Drop wired-id bookkeeping for connections no longer in the pool
    /// (gap G19 — the sets were grow-only, which silently disabled the
    /// return paths for a forget-then-re-add of the same satellite id).
    private func pruneReturnPathWiring(to pool: [String: WifiConnection]) {
        rumbleWiredConnections.formIntersection(pool.keys)
        lightbarWiredConnections.formIntersection(pool.keys)
    }

    /// Install the rumble handler on every WifiConnection in `pool` that
    /// doesn't already have one. The handler walks the current bindings
    /// (slotId → connectionId), finds the slot bound to *this* connection,
    /// and forwards the `MSG_RUMBLE` payload to `GameControllerInput` for that
    /// slot id (== device id, by construction in `rebuildSlots`).
    ///
    /// The handler drives vibration only — the light bar is a separate return
    /// path (`installLightbarHandlers`). Vibration is gated on the Rumble
    /// toggle.
    private func installRumbleHandlers(_ pool: [String: WifiConnection]? = nil) {
        let input = self.input
        let hub = self.hub
        let gate = self.gate
        for (id, conn) in pool ?? wifi.connections {
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
        input.processor.touchpadSender = { deviceId, f0a, f0id, f0x, f0y, f1a, f1id, f1x, f1y, btn, eventTimeMs in
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
                buttonPressed: btn,
                eventTimeMs: eventTimeMs
            )
        }
    }

    /// Install the light-bar handler on every pooled WifiConnection — same
    /// install-once / re-walk-on-pool-change pattern as `installRumbleHandlers`.
    /// The handler resolves the bound slot and applies the host-game colour to
    /// that controller, unless the user set the light bar to "Off".
    private func installLightbarHandlers(_ pool: [String: WifiConnection]? = nil) {
        let input = self.input
        let hub = self.hub
        let gate = self.gate
        for (id, conn) in pool ?? wifi.connections {
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
            let status = BatteryStatus(rawValue: statusRaw) ?? .unknown
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
        // the `capMotion` / `capLightbar` bits in the REST descriptor's caps
        // word (declarative session PUT / per-slot converge). Both default
        // to false for an unknown slot id.
        let caps = slots.first { $0.id == slotId }?.capabilities
        hub.bind(
            slotId: slotId,
            connectionId: connectionId,
            hasMotion: caps?.hasMotion ?? false,
            hasLight: caps?.hasLightbar ?? false
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
