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
    /// The per-controller switches beneath the global ones.
    package let slotPreferences: SlotPreferenceStore
    /// What the Diagnostics window reads, ticking while it is open.
    package let diagnostics: DiagnosticsSource
    /// The flight recorder's lines.
    package let diagnosticsLog = DiagnosticsLogStore()
    /// The crash log an earlier run may have left.
    package let crashLog: CrashLog
    /// Controller audio: the routes, the mutes, the permission, the engine.
    let audio: AudioPipeline
    /// The input inspector, armed on one controller while its sheet is open.
    package let inspector: InputInspector
    /// The Share crash reports switch; the uploader behind it is the app's.
    package let crashReporting: CrashReportingController

    @Published package private(set) var slots: [ControllerSlot] = []
    @Published package private(set) var connections: [ConnectionSummary] = []
    /// The satellite that asked for a PIN; the app presents the sheet.
    @Published package var pairingTarget: DiscoveredServer?
    /// The most recent failure, until the app clears it.
    @Published package private(set) var lastFailure: ConnectionFailure?
    /// Every failure as it happens, for a banner.
    package let failures = PassthroughSubject<ConnectionFailure, Never>()
    /// The app-wide microphone word the header's chip shows.
    @Published package private(set) var micIndicator = MicIndicatorState.hidden
    /// Whether the system lets Dish capture a microphone.
    @Published package private(set) var micPermitted = true

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
    private let recorder: DiagnosticsRecorder
    private var cancellables = Set<AnyCancellable>()

    /// The app's entry point: production stores, the host's lifecycle
    /// signals, the running build's version for the update check, the crash
    /// uploader behind the Share crash reports switch.
    package convenience init(
        lifecycle: LifecycleSignals,
        appVersion: String,
        crashLog: CrashLog,
        crashUploader: CrashUploader
    ) {
        self.init(
            store: ConnectionStore(),
            lifecycle: lifecycle,
            appVersion: appVersion,
            crashLog: crashLog,
            crashUploader: crashUploader
        )
    }

    init(
        inhibitor: WakeInhibitor? = nil,
        store: ConnectionStore = ConnectionStore(),
        lifecycle: LifecycleSignals = .none,
        defaults: UserDefaults = .standard,
        manifestGateway: ManifestGateway? = nil,
        appVersion: String = "0.0.0",
        crashLog: CrashLog = CrashLog(url: URL(fileURLWithPath: "/dev/null")),
        audioDependencies: AudioDependencies? = nil,
        crashUploader: CrashUploader? = nil
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
        diagnostics = DiagnosticsSource(wifi: wifi, hub: hub)
        recorder = DiagnosticsRecorder(store: diagnosticsLog)
        self.crashLog = crashLog
        let routing = InputRouting()
        self.routing = routing
        returnPaths = ReturnPathRouter(input: input, gate: gate, table: routing.table)
        let slotPreferences = SlotPreferenceStore(defaults: defaults)
        self.slotPreferences = slotPreferences
        audio = AudioPipeline(
            hub: hub,
            wifi: wifi,
            input: input,
            slotPreferences: slotPreferences,
            dependencies: audioDependencies ?? .live()
        )
        inspector = InputInspector(processor: input.processor)
        crashReporting = CrashReportingController(defaults: defaults, uploader: crashUploader)
        wireObservers(pipeline: pipeline, lifecycle: lifecycle)
    }

    /// The gate and the routing table installed first, then the observers
    /// in their order: the slot list and the routing table, the pipelines
    /// started, the return paths, the settings, the events and the host's
    /// lifecycle, and the remembered satellites last.
    private func wireObservers(pipeline: WakePipeline, lifecycle: LifecycleSignals) {
        gate.update(settings.flags)
        routing.install(on: input.processor)
        observeSlots()
        observeRoutingTable()
        observeDiagnostics()
        pipeline.start()
        updates.start()
        audio.start()
        observeMicIndicator()
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
        let picks = Publishers.CombineLatest3(
            wifi.typeOverrides.statePublisher,
            wifi.motionStatus.statePublisher,
            slotPreferences.statePublisher
        )
        let sound = Publishers.CombineLatest3(audio.routes.statePublisher, audio.engine.statePublisher, audio.mutes.statePublisher)
        Publishers.CombineLatest4(input.$slots, hub.$connections, hub.$bindings, Publishers.CombineLatest(picks, sound))
            .sink { [weak self] gcSlots, connections, bindings, facts in
                let (overrides, motion, preferences) = facts.0
                let (routes, audio, mutes) = facts.1
                let snapshot = SlotFactsSnapshot(
                    overrides: overrides,
                    motion: motion,
                    preferences: preferences,
                    routes: routes,
                    audio: audio,
                    mutes: mutes
                )
                self?.rebuildSlots(gcSlots: gcSlots, connections: connections, bindings: bindings, facts: snapshot)
            }
            .store(in: &cancellables)
    }

    private func observeMicIndicator() {
        audio.indicator.statePublisher
            .sink { [weak self] state in self?.micIndicator = state }
            .store(in: &cancellables)
        audio.permission.statePublisher
            .sink { [weak self] permitted in self?.micPermitted = permitted }
            .store(in: &cancellables)
    }

    /// The flight recorder reads what the UI renders; the window's source
    /// reads the slot list the same way.
    private func observeDiagnostics() {
        diagnostics.useSlots { [weak self] in self?.slots ?? [] }
        diagnostics.useAudio { [weak self] slotId in self?.audio.padDiagnostics(slotId) }
        hub.$connections
            .sink { [weak self] rows in self?.recorder.observeLinks(rows) }
            .store(in: &cancellables)
        $slots
            .sink { [weak self] slots in self?.recorder.observeSlots(slots) }
            .store(in: &cancellables)
    }

    /// The table and every connection's switches follow the bindings, the
    /// pool, the global switches and the per-controller ones. The emitted
    /// values are used, not the properties: `@Published` delivers before the
    /// write lands.
    private func observeRoutingTable() {
        let globalSwitches = settings.objectWillChange.afterMutationSettles().map { _ in () }.prepend(())
        let switches = Publishers.CombineLatest(globalSwitches, slotPreferences.statePublisher)
        Publishers.CombineLatest3(hub.$bindings, wifi.$connections, switches)
            .sink { [weak self] bindings, pool, switches in
                self?.refreshRouting(bindings: bindings, pool: pool, preferences: switches.1)
            }
            .store(in: &cancellables)
    }

    /// One fold feeds both the hot path's table and the descriptors: a
    /// changed claim re-sends a live slot's descriptor whole.
    private func refreshRouting(bindings: [String: String], pool: [String: WifiConnection], preferences: [String: SlotPreferences]) {
        let global = settings.flags
        let flags = connectionFlags(bindings: bindings, connectionIds: pool.keys, global: global, preferences: preferences)
        routing.table.set(routeSnapshot(bindings: bindings, pool: pool, flags: flags, global: global))
        for (id, conn) in pool {
            conn.setForwardingFlags(flags[id] ?? global)
        }
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

    /// The light bar's return path reads the global switch alone.
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
    /// The catalogs and probes are read here; the rest arrived with the
    /// emission.
    private func rebuildSlots(
        gcSlots: [GameControllerInput.Slot],
        connections: [ConnectionSummary],
        bindings: [String: String],
        facts: SlotFactsSnapshot
    ) {
        let known = Set(gcSlots.map(\.id))
        for (slotId, _) in bindings where !known.contains(slotId) {
            hub.unbind(slotId: slotId)
        }
        var facts = facts
        facts.catalogs = wifi.catalogs
        facts.probes = wifi.capabilities
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

    /// The bound pad's detected capabilities, with its audio route folded
    /// in, become the descriptor's claims, and its family picks the catalog
    /// type it is emulated as.
    package func bind(slotId: String, connectionId: String) {
        let pad = input.slots.first { $0.id == slotId }
        let capabilities = (pad?.capabilities ?? .none).withAudio(audio.routes.state[slotId]?.function)
        hub.bind(slotId: slotId, connectionId: connectionId, capabilities: capabilities, family: pad?.family ?? .other)
    }

    package func unbind(slotId: String) {
        hub.unbind(slotId: slotId)
    }

    /// Flip one of a controller's own switches; the global one in Settings
    /// still outranks it.
    package func setSlotSwitch(_ feature: SlotSwitch, on: Bool, slotId: String) {
        switch feature {
        case .motion: slotPreferences.setMotion(on, for: slotId)
        case .rumble: slotPreferences.setRumble(on, for: slotId)
        case .touchpad: slotPreferences.setTouchpad(on, for: slotId)
        case .mic:
            slotPreferences.setMic(on, for: slotId)
            if on { audio.requestMicrophoneLeave() }
        case .speaker: slotPreferences.setSpeaker(on, for: slotId)
        }
    }

    /// The touchpad's pick: the pad render, the host's mouse, or off. A
    /// pick that changes the session's desire re-PUTs the session.
    package func setTouchpadPick(_ pick: TouchpadPick, slotId: String) {
        slotPreferences.setTouchpadPick(pick, for: slotId)
    }

    /// Mute or unmute one controller's microphone; muted sends nothing.
    package func setMicMuted(_ muted: Bool, slotId: String) {
        audio.mutes.setMuted(muted, for: slotId)
    }

    /// The header chip's click: every live microphone mutes together, every
    /// muted one comes back together.
    package func toggleAllMics() {
        audio.toggleAllMics()
    }

    /// Emulate the bound pad as `type`, or as its own family again for nil.
    package func setEmulatedType(slotId: String, type: Int?) {
        let pad = input.slots.first { $0.id == slotId }
        hub.setEmulatedType(slotId: slotId, type: type, family: pad?.family ?? .other)
    }
}

/// The switches in force per satellite: the global ones folded with the
/// bound controller's own, or the global ones alone while nothing is bound.
func connectionFlags(
    bindings: [String: String],
    connectionIds: some Collection<String>,
    global: ForwardingFlags,
    preferences: [String: SlotPreferences]
) -> [String: ForwardingFlags] {
    Dictionary(uniqueKeysWithValues: connectionIds.map { id in
        let slotId = bindings.first { $0.value == id }?.key
        let slot = slotId.flatMap { preferences[$0] } ?? SlotPreferences()
        return (id, effectiveFlags(global: global, slot: slot))
    })
}

/// The hot path's table, both views at once: slot → live sink and its
/// switches, satellite → bound slot and the same switches. A slot bound to
/// a Moonlight host routes to its pad on that host's link, under the
/// switches folded for the slot itself: the host carries up to four pads,
/// so the switches are the slot's, never the connection's.
func routeSnapshot(
    bindings: [String: String],
    pool: [String: WifiConnection],
    flags: [String: ForwardingFlags],
    global: ForwardingFlags,
    moonlight: [String: MoonlightConnection] = [:],
    preferences: [String: SlotPreferences] = [:]
) -> RoutingSnapshot {
    var snapshot = RoutingSnapshot()
    for (slotId, connectionId) in bindings {
        if let conn = pool[connectionId] {
            let inForce = flags[connectionId] ?? global
            snapshot.bySlot[slotId] = Route(sink: conn, flags: inForce)
            snapshot.byConnection[connectionId] = BoundSlotRoute(slotId: slotId, flags: inForce)
        } else if let host = moonlight[connectionId] {
            let inForce = effectiveFlags(global: global, slot: preferences[slotId] ?? SlotPreferences())
            snapshot.bySlot[slotId] = Route(sink: MoonlightPadSink(link: host.link, slotId: slotId), flags: inForce)
        }
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
    var preferences: [String: SlotPreferences] = [:]
    var routes: [String: PadAudioRoute] = [:]
    var audio: [String: ControllerAudioState] = [:]
    var mutes: Set<String> = []
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
        let route = facts.routes[gc.id]
        var slot = ControllerSlot(id: gc.id, name: gc.name, capabilities: gc.capabilities.withAudio(route?.function), battery: gc.battery)
        slot.preferences = facts.preferences[gc.id] ?? SlotPreferences()
        slot.audioRoute = route?.verdict
        slot.micMuted = facts.mutes.contains(gc.id)
        guard let connectionId = bindings[gc.id] else { return slot }
        slot.boundConnectionId = connectionId
        slot.boundStatus = connections.first { $0.id == connectionId }
        slot.audio = facts.audio[gc.id]
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
