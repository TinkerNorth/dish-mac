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

    @Published private(set) var slots: [ControllerSlot] = []
    @Published private(set) var connections: [ConnectionSummary] = []

    /// Set when the server asks us to re-pair with a PIN. Bound to a sheet.
    @Published var pairingTarget: DiscoveredServer?
    /// Transient error banner.
    @Published var errorMessage: String?

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
        self.store = store
        self.wifi = wifi
        self.hub = hub
        self.input = input
        self.wake = ScreenWakeController(inhibitor: inhibitor ?? IOKitDisplaySleepInhibitor())

        observe()
        installReportSender()
        installRumbleHandlers()
        // Auto-reconnect every remembered server on launch.
        wifi.autoReconnectAll()
    }

    /// Tracks which `WifiConnection` ids we've already attached the rumble
    /// handler to. WifiConnections live until they're forgotten, so this set
    /// only ever grows during a session — perfect for an "install once,
    /// re-install on reconnect via the WifiConnection" pattern.
    private var rumbleWiredConnections = Set<String>()

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

        // Make sure every newly-pooled WifiConnection has its rumble handler
        // installed. The pool only grows during a session — `register` adds
        // entries, `forget` removes — so we re-walk it on each pool change.
        wifi.$connections
            .sink { [weak self] _ in self?.installRumbleHandlers() }
            .store(in: &cancellables)

        // Surface pairing + error events to the UI.
        wifi.events
            .sink { [weak self] ev in
                guard let self else { return }
                switch ev {
                case let .pairingRequired(server): self.pairingTarget = server
                case let .error(msg): self.errorMessage = msg
                }
            }
            .store(in: &cancellables)
    }

    private func rebuildSlots(
        gcSlots: [GameControllerInput.Slot],
        conns: [ConnectionSummary],
        bindings: [String: String]
    ) {
        var next: [ControllerSlot] = []
        for gc in gcSlots {
            next.append(ControllerSlot(id: gc.id, name: gc.name))
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
    /// and forwards the rumble payload to `GameControllerInput.applyRumble`
    /// for that slot id (== device id, by construction in `rebuildSlots`).
    private func installRumbleHandlers() {
        let input = self.input
        let hub = self.hub
        for (id, conn) in wifi.connections {
            if rumbleWiredConnections.contains(id) { continue }
            rumbleWiredConnections.insert(id)
            conn.setRumbleHandler { rm in
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
                        durationMs: rm.durationMs,
                        hasLightbar: rm.hasLightbar,
                        lightbarR: rm.lightbarR,
                        lightbarG: rm.lightbarG,
                        lightbarB: rm.lightbarB
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
        hub.bind(slotId: slotId, connectionId: connectionId)
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
