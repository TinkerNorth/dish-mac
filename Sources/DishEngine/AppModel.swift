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
    let wake: WakeStateController
    package let settings: FeatureSettings
    package let theme: ThemePreferenceStore
    package let background: BackgroundPreferenceStore
    package let keepAwake: KeepAwakePreferenceStore
    package let updatePreferences: UpdatePreferenceStore
    package let updates: UpdateChecker

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
    /// Bound slots whose connection streams.
    private let streamingCount: Composer<Int>
    /// Whether a pad was used inside the keep-awake window.
    let activity: ControllerActivitySource
    /// How far the machine is held awake, from the count, the activity and
    /// the preferences; the wake controller follows it.
    private let wakeState: Composer<WakeState>
    private var cancellables = Set<AnyCancellable>()

    /// The app's entry point: production stores, the host's lifecycle
    /// signals, the running build's version for the update check.
    package convenience init(lifecycle: LifecycleSignals, appVersion: String) {
        self.init(store: ConnectionStore(), lifecycle: lifecycle, appVersion: appVersion)
    }

    init(
        inhibitor: WakeInhibitor? = nil,
        store: ConnectionStore = ConnectionStore(),
        lifecycle: LifecycleSignals = .none,
        defaults: UserDefaults = .standard,
        manifestGateway: ManifestGateway? = nil,
        appVersion: String = "0.0.0"
    ) {
        let wifi = WifiConnectionManager(store: store)
        let hub = ConnectionHub(wifi: wifi, store: store)
        let input = GameControllerInput()
        self.store = store
        self.wifi = wifi
        self.hub = hub
        self.input = input
        settings = FeatureSettings(defaults: defaults)
        theme = ThemePreferenceStore(defaults: defaults)
        background = BackgroundPreferenceStore(defaults: defaults)
        let keepAwake = KeepAwakePreferenceStore(defaults: defaults)
        self.keepAwake = keepAwake
        let updatePreferences = UpdatePreferenceStore(defaults: defaults)
        self.updatePreferences = updatePreferences
        updates = UpdateChecker(
            preferences: updatePreferences,
            gateway: manifestGateway ?? Self.releaseManifestGateway(),
            currentVersion: appVersion
        )
        let pipeline = WakePipeline(
            hub: hub, processor: input.processor, keepAwake: keepAwake, inhibitor: inhibitor ?? IOKitWakeInhibitor()
        )
        streamingCount = pipeline.streamingCount
        activity = pipeline.activity
        wakeState = pipeline.wakeState
        wake = pipeline.wake
        routing = InputRouting(gate: gate)
        returnPaths = ReturnPathRouter(input: input, gate: gate, bindings: hub.currentBindings)
        gate.update(settings.flags)
        wifi.applyForwardingFlags(settings.flags)
        routing.install(on: input.processor)
        observeSlots()
        observeRoutingTable()
        pipeline.start()
        updates.start()
        observeReturnPathWiring()
        observeSettings()
        observeEvents()
        installLifecycleHandling(lifecycle)
        wifi.autoReconnectAll()
    }

    /// The release permalink, read through URLSession.
    private static func releaseManifestGateway() -> ManifestGateway {
        guard let url = URL(string: UpdateManifest.latestManifestURLString) else {
            return URLSessionManifestGateway(url: URL(fileURLWithPath: "/dev/null"))
        }
        return URLSessionManifestGateway(url: url)
    }

    // MARK: - Wiring

    private func observeSlots() {
        let picks = Publishers.CombineLatest(wifi.typeOverrides.statePublisher, wifi.motionStatus.statePublisher)
        Publishers.CombineLatest4(input.$slots, hub.$connections, hub.$bindings, picks)
            .sink { [weak self] gcSlots, connections, bindings, picks in
                self?.rebuildSlots(gcSlots: gcSlots, connections: connections, bindings: bindings, overrides: picks.0, motion: picks.1)
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
        wifi.applyForwardingFlags(settings.flags)
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
    private func rebuildSlots(
        gcSlots: [GameControllerInput.Slot],
        connections: [ConnectionSummary],
        bindings: [String: String],
        overrides: [SlotKey: Int],
        motion: [SlotKey: MotionBackendStatus]
    ) {
        let known = Set(gcSlots.map(\.id))
        for (slotId, _) in bindings where !known.contains(slotId) {
            hub.unbind(slotId: slotId)
        }
        let facts = SlotFactsSnapshot(catalogs: wifi.catalogs, probes: wifi.capabilities, overrides: overrides, motion: motion)
        slots = composeSlots(gcSlots: gcSlots, connections: connections, bindings: bindings, facts: facts)
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

    /// The bound pad's detected capabilities become the descriptor's claims,
    /// and its family picks the catalog type it is emulated as.
    package func bind(slotId: String, connectionId: String) {
        let pad = input.slots.first { $0.id == slotId }
        hub.bind(
            slotId: slotId,
            connectionId: connectionId,
            capabilities: pad?.capabilities ?? .none,
            family: pad?.family ?? .other
        )
    }

    package func unbind(slotId: String) {
        hub.unbind(slotId: slotId)
    }

    /// Emulate the bound pad as `type`, or as its own family again for nil.
    package func setEmulatedType(slotId: String, type: Int?) {
        let pad = input.slots.first { $0.id == slotId }
        hub.setEmulatedType(slotId: slotId, type: type, family: pad?.family ?? .other)
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

/// What the slot list reads beside the bindings: the catalogs and probes
/// per satellite, the Emulate picks and the motion words per binding.
struct SlotFactsSnapshot {
    var catalogs: [String: CatalogDTO] = [:]
    var probes: [String: ServerCapabilitiesDTO] = [:]
    var overrides: [SlotKey: Int] = [:]
    var motion: [SlotKey: MotionBackendStatus] = [:]
}

/// The UI's slot list: every connected controller, with its binding's
/// connection summary and the binding's facts attached.
func composeSlots(
    gcSlots: [GameControllerInput.Slot],
    connections: [ConnectionSummary],
    bindings: [String: String],
    facts: SlotFactsSnapshot = SlotFactsSnapshot()
) -> [ControllerSlot] {
    gcSlots.map { gc in
        var slot = ControllerSlot(id: gc.id, name: gc.name, capabilities: gc.capabilities, battery: gc.battery)
        guard let connectionId = bindings[gc.id] else { return slot }
        slot.boundConnectionId = connectionId
        slot.boundStatus = connections.first { $0.id == connectionId }
        attachBindingFacts(to: &slot, gc: gc, connectionId: connectionId, facts: facts)
        return slot
    }
}

/// The emulated type and its facts, the host's facts and the motion word
/// for one binding.
func attachBindingFacts(to slot: inout ControllerSlot, gc: GameControllerInput.Slot, connectionId: String, facts: SlotFactsSnapshot) {
    let key = SlotKey(connectionId: connectionId, slotId: gc.id)
    let catalog = facts.catalogs[connectionId]
    let override = facts.overrides[key]
    let type = emulatedControllerType(override: override, catalog: catalog, family: gc.family)
    slot.emulation = SlotEmulation(type: type, isOverride: override != nil, offered: offerableTypes(in: catalog))
    slot.typeFeatures = typeFeatureFacts(in: catalog, type: type)
    slot.hostProbe = hostProbeFacts(facts.probes[connectionId])
    slot.motionStatus = facts.motion[key]
}
