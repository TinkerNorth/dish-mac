// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Combine
import DishCore
import DishKernel
import Foundation

/// The composition root: owns the network and input layers, derives the slot
/// list the UI binds, routes the hot path, and relays the manager's failures
/// as data for the app to word.
@MainActor
package final class AppModel: ObservableObject {

    let store: ConnectionStore
    package let wifi: WifiConnectionManager
    let hub: ConnectionHub
    let input: GameControllerInput
    let wake: ScreenWakeController
    package let settings: FeatureSettings

    @Published package private(set) var slots: [ControllerSlot] = []
    @Published package private(set) var connections: [ConnectionSummary] = []
    /// The satellite that asked for a PIN; the app presents the sheet.
    @Published package var pairingTarget: DiscoveredServer?
    /// The most recent failure, until the app clears it.
    @Published package private(set) var lastFailure: ConnectionFailure?
    /// Every failure as it happens, for a banner.
    package let failures = PassthroughSubject<ConnectionFailure, Never>()

    /// Thread-safe mirror of `settings` for the callback threads.
    private let gate = ForwardingGate()
    private let routing: InputRouting
    private let returnPaths: ReturnPathRouter
    /// Bound slots whose connection streams; the wake controller follows it.
    private let streamingCount: Composer<Int>
    private var cancellables = Set<AnyCancellable>()

    /// The app's entry point: production stores, the host's lifecycle signals.
    package convenience init(lifecycle: LifecycleSignals) {
        self.init(inhibitor: nil, store: ConnectionStore(), lifecycle: lifecycle)
    }

    init(inhibitor: DisplaySleepInhibitor? = nil, store: ConnectionStore = ConnectionStore(), lifecycle: LifecycleSignals = .none) {
        let wifi = WifiConnectionManager(store: store)
        let hub = ConnectionHub(wifi: wifi, store: store)
        let input = GameControllerInput()
        self.store = store
        self.wifi = wifi
        self.hub = hub
        self.input = input
        settings = FeatureSettings()
        let streamingCount = Composer(hub.$bindings, hub.$connections, initial: 0, transform: streamingSlotCount)
        self.streamingCount = streamingCount
        wake = ScreenWakeController(upstream: streamingCount.statePublisher, inhibitor: inhibitor ?? IOKitDisplaySleepInhibitor())
        routing = InputRouting(gate: gate)
        returnPaths = ReturnPathRouter(input: input, gate: gate, bindings: hub.currentBindings)
        gate.update(settings.flags)
        routing.install(on: input.processor)
        observeSlots()
        observeRoutingTable()
        wake.start()
        observeReturnPathWiring()
        observeSettings()
        observeEvents()
        installLifecycleHandling(lifecycle)
        wifi.autoReconnectAll()
    }

    // MARK: - Wiring

    private func observeSlots() {
        Publishers.CombineLatest3(input.$slots, hub.$connections, hub.$bindings)
            .sink { [weak self] gcSlots, connections, bindings in
                self?.rebuildSlots(gcSlots: gcSlots, connections: connections, bindings: bindings)
            }
            .store(in: &cancellables)
    }

    private func observeRoutingTable() {
        Publishers.CombineLatest(hub.$bindings, wifi.$connections)
            .sink { [weak self] bindings, pool in
                self?.routing.table.set(routeSnapshot(bindings: bindings, pool: pool))
            }
            .store(in: &cancellables)
    }

    /// The emitted pool is walked, not the property: `@Published` delivers
    /// before the write lands.
    private func observeReturnPathWiring() {
        wifi.$connections
            .sink { [weak self] pool in self?.returnPaths.wire(pool) }
            .store(in: &cancellables)
    }

    private func observeSettings() {
        settings.objectWillChange
            .afterMutationSettles()
            .sink { [weak self] _ in self?.syncGate() }
            .store(in: &cancellables)
    }

    private func syncGate() {
        gate.update(settings.flags)
    }

    private func observeEvents() {
        wifi.events
            .sink { [weak self] event in self?.handle(event) }
            .store(in: &cancellables)
    }

    private func handle(_ event: ConnectionEvent) {
        switch event {
        case let .pairingRequired(server):
            pairingTarget = server
        case let .failure(failure):
            lastFailure = failure
            failures.send(failure)
        }
    }

    /// Focus loss and sleep both release every held input, because the
    /// controller callbacks stop reaching this process and a held button
    /// would otherwise stay pressed on the virtual pad until heartbeat death.
    /// Wake reconnects resting rows at once.
    private func installLifecycleHandling(_ lifecycle: LifecycleSignals) {
        lifecycle.focusLost
            .sink { [weak self] in self?.releaseAllInputs() }
            .store(in: &cancellables)
        lifecycle.willSleep
            .sink { [weak self] in self?.releaseAllInputs() }
            .store(in: &cancellables)
        lifecycle.didWake
            .sink { [weak self] in self?.wifi.resumeAfterWake() }
            .store(in: &cancellables)
    }

    private func releaseAllInputs() {
        input.processor.zeroAndSendAll()
    }

    // MARK: - Slots

    /// Rebuild the slot list and evict bindings whose controller is gone.
    private func rebuildSlots(gcSlots: [GameControllerInput.Slot], connections: [ConnectionSummary], bindings: [String: String]) {
        let known = Set(gcSlots.map(\.id))
        for (slotId, _) in bindings where !known.contains(slotId) {
            hub.unbind(slotId: slotId)
        }
        slots = composeSlots(gcSlots: gcSlots, connections: connections, bindings: bindings)
        self.connections = connections
    }

    // MARK: - UI actions

    package func clearFailure() {
        lastFailure = nil
    }

    package func disconnect(_ id: String) {
        wifi.disconnect(id: id)
    }

    package func connect(_ server: DiscoveredServer) {
        wifi.connect(to: server)
    }

    /// False when `input` is not a usable IPv4 address.
    @discardableResult
    package func connectManual(_ input: String) -> Bool {
        guard let server = DiscoveredServer.manual(from: input) else { return false }
        wifi.connect(to: server)
        return true
    }

    package func forget(_ id: String) {
        wifi.forget(id: id)
    }

    package func startScan() {
        wifi.startDiscovery()
    }

    package func pairWithPin(_ server: DiscoveredServer, pin: String) {
        wifi.pairWithPin(server, pin: pin)
    }

    /// The bound controller's detected capabilities decide the descriptor's
    /// motion and light-bar bits.
    package func bind(slotId: String, connectionId: String) {
        let capabilities = slots.first { $0.id == slotId }?.capabilities ?? .none
        hub.bind(
            slotId: slotId,
            connectionId: connectionId,
            hasMotion: capabilities.hasMotion,
            hasLight: capabilities.hasLightbar
        )
    }

    package func unbind(slotId: String) {
        hub.unbind(slotId: slotId)
    }
}

/// The slot id to live connection table the hot path reads.
func routeSnapshot(bindings: [String: String], pool: [String: WifiConnection]) -> [String: WifiConnection] {
    var snapshot: [String: WifiConnection] = [:]
    for (slotId, connectionId) in bindings {
        if let conn = pool[connectionId] { snapshot[slotId] = conn }
    }
    return snapshot
}

/// The UI's slot list: every connected controller, with its binding's
/// connection summary attached.
func composeSlots(gcSlots: [GameControllerInput.Slot], connections: [ConnectionSummary], bindings: [String: String]) -> [ControllerSlot] {
    gcSlots.map { gc in
        var slot = ControllerSlot(id: gc.id, name: gc.name, capabilities: gc.capabilities, battery: gc.battery)
        if let connectionId = bindings[gc.id] {
            slot.boundConnectionId = connectionId
            slot.boundStatus = connections.first { $0.id == connectionId }
        }
        return slot
    }
}
