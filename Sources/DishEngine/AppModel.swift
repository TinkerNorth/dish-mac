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
    /// Each pad's dead zones, handed to the processor as the pad attaches.
    package let deadzonePreferences: DeadzonePreferenceStore
    /// Events, sends and each pad's rates, ticking while Home or Controllers shows.
    package let telemetry = TelemetrySource()
    /// The one binding apply's ears and clock.
    let bindingWatch = BindingApplyWatch()
    /// What the Diagnostics page reads, ticking while it shows.
    package let diagnostics: DiagnosticsSource
    /// The flight recorder's lines.
    package let diagnosticsLog = DiagnosticsLogStore()
    /// The crash log an earlier run may have left.
    package let crashLog: CrashLog
    /// Controller audio: the routes, the mutes, the permission, the engine.
    let audio: AudioPipeline
    /// The input inspector, armed on one controller while its page shows.
    package let inspector: InputInspector
    /// The Share crash reports switch; the uploader behind it is the app's.
    package let crashReporting: CrashReportingController
    /// The Moonlight hosts: discovery, pairing, and the sessions the bindings ask for.
    package let moonlight: MoonlightConnectionManager

    @Published package private(set) var slots: [ControllerSlot] = []
    @Published package private(set) var connections: [ConnectionSummary] = []
    /// The satellite whose row shows the pairing card.
    @Published package internal(set) var pairingTarget: DiscoveredServer?
    /// The Moonlight host that minted a PIN for the user to type into it; its row shows the card.
    @Published package internal(set) var moonlightPin: MoonlightPinPrompt?
    /// The most recent failure, until the app clears it.
    @Published package internal(set) var lastFailure: ConnectionFailure?
    /// Every failure as it happens, for a banner.
    package let failures = PassthroughSubject<ConnectionFailure, Never>()
    /// The app-wide microphone word the header's chip shows.
    @Published package private(set) var micIndicator = MicIndicatorState.hidden
    /// Whether the system lets Dish capture a microphone.
    @Published package private(set) var micPermitted = true
    /// What the shell shows beyond the slot list: the keep-awake reach, the
    /// update check, and whether a crash report waits.
    @Published package internal(set) var shellFacts = ShellFacts()

    /// Thread-safe mirror of `settings` for the callback threads.
    private let gate = ForwardingGate()
    let routing = InputRouting()
    private let returnPaths: ReturnPathRouter
    /// A host's rumble and lamp onto the pad bound to the number it names.
    let moonlightFeedback: MoonlightFeedbackRouter
    /// What the bindings last asked of the hosts, so an unchanged desire converges nothing.
    var lastDesired: [String: [MoonlightPadRequest]] = [:]
    /// Bound slots whose connection streams.
    let streamingCount: Composer<Int>
    /// Whether a pad was used inside the keep-awake window.
    let activity: ControllerActivitySource
    /// How far the machine is held awake, from the count, the activity and
    /// the preferences; the wake controller follows it.
    let wakeState: Composer<WakeState>
    private let recorder: DiagnosticsRecorder
    /// Whether the lid closed on a stream, across one sleep.
    let lidWatch: LidWatch
    var cancellables = Set<AnyCancellable>()

    /// The app's entry point: production stores, the host's lifecycle
    /// signals, the running build's version for the update check, the crash
    /// uploader behind the Share crash reports switch.
    package convenience init(
        lifecycle: LifecycleSignals,
        appVersion: String,
        crashLog: CrashLog,
        crashUploader: CrashUploader
    ) {
        let store = ConnectionStore()
        let gateway = MoonlightGateway(identity: nil, pins: store)
        let moonlight = MoonlightConnectionManager(store: MoonlightHostStore(), gateway: gateway, identity: nil)
        self.init(
            store: store,
            lifecycle: lifecycle,
            appVersion: appVersion,
            crashLog: crashLog,
            crashUploader: crashUploader,
            moonlight: moonlight,
            hidPads: IOKitHidPadReader()
        )
        Self.mintMoonlightIdentity(into: moonlight, gateway: gateway)
    }

    /// The dish's Moonlight identity, RSA-2048 born in the keychain: minted
    /// off the main thread, once, and adopted by the gateway (mutual TLS) and
    /// the manager (pairing) when it is ready. A pairing before that fails
    /// as having no identity; a secure call presents no certificate.
    private static func mintMoonlightIdentity(into manager: MoonlightConnectionManager, gateway: MoonlightGateway) {
        Task.detached(priority: .utility) {
            guard let identity = MoonlightIdentityStore.loadOrCreate() else { return }
            await MainActor.run {
                gateway.adoptIdentity(identity)
                manager.adoptIdentity(identity)
            }
        }
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
        crashUploader: CrashUploader? = nil,
        moonlight: MoonlightConnectionManager? = nil,
        clamshell: ClamshellStateReading? = nil,
        hidCensus: HidCensusReading? = nil,
        hidPads: HidPadReading? = nil,
        discovery: WifiConnectionManager.DiscoveryPaths = .live,
        approvalPolling: WifiConnectionManager.ApprovalPolling = .standard
    ) {
        let wifi = WifiConnectionManager(store: store, approvalPolling: approvalPolling, discovery: discovery)
        let moonlight = moonlight ?? Self.defaultMoonlight(defaults: defaults, store: store)
        let hub = ConnectionHub(wifi: wifi, store: store, moonlight: moonlight)
        let prefs = AppPreferenceStores(defaults: defaults)
        let input = GameControllerInput(paths: InputPaths(choices: prefs.usbPaths, reader: hidPads ?? InertHidPadReader()))
        self.store = store
        self.wifi = wifi
        self.moonlight = moonlight
        self.hub = hub
        self.input = input
        settings = prefs.settings
        theme = prefs.theme
        background = prefs.background
        keepAwake = prefs.keepAwake
        updatePreferences = prefs.updates
        slotPreferences = prefs.slots
        deadzonePreferences = prefs.deadzones
        updates = Self.updateChecker(preferences: prefs.updates, manifestGateway: manifestGateway, appVersion: appVersion)
        let pipeline = WakePipeline(
            hub: hub,
            processor: input.processor,
            keepAwake: prefs.keepAwake,
            inhibitor: inhibitor ?? IOKitWakeInhibitor()
        )
        streamingCount = pipeline.streamingCount
        activity = pipeline.activity
        wakeState = pipeline.wakeState
        wake = pipeline.wake
        diagnostics = DiagnosticsSource(wifi: wifi, hub: hub, moonlight: moonlight, census: hidCensus ?? IOKitHidCensus())
        recorder = DiagnosticsRecorder(store: diagnosticsLog)
        self.crashLog = crashLog
        returnPaths = ReturnPathRouter(actuators: .live(input), gate: gate, table: routing.table)
        moonlightFeedback = MoonlightFeedbackRouter(actuators: .live(input), gate: gate, table: routing.table)
        audio = AudioPipeline(
            hub: hub,
            wifi: wifi,
            input: input,
            slotPreferences: prefs.slots,
            dependencies: audioDependencies ?? .live()
        )
        inspector = InputInspector(processor: input.processor)
        crashReporting = CrashReportingController(defaults: defaults, uploader: crashUploader)
        lidWatch = LidWatch(clamshell: clamshell ?? IOKitClamshellState())
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
        observeDeadzones()
        observeRoutingTable()
        observeMoonlight()
        observeDiagnostics()
        pipeline.start()
        updates.start()
        audio.start()
        observeMicIndicator()
        observeReturnPathWiring()
        observeSettings()
        observeEvents()
        observePairing()
        observeShellFacts()
        installLifecycleHandling(lifecycle)
        wifi.autoReconnectAll()
    }

    /// A manager with no identity yet: the one a test gets, and the one the
    /// production init hands an identity once the keychain has minted it.
    private static func defaultMoonlight(defaults: UserDefaults, store: ConnectionStore) -> MoonlightConnectionManager {
        MoonlightConnectionManager(
            store: MoonlightHostStore(defaults: defaults),
            gateway: MoonlightGateway(identity: nil, pins: store),
            identity: nil
        )
    }

    /// The update check over the release permalink, or the gateway a test hands in.
    private static func updateChecker(
        preferences: UpdatePreferenceStore,
        manifestGateway: ManifestGateway?,
        appVersion: String
    ) -> UpdateChecker {
        UpdateChecker(preferences: preferences, gateway: manifestGateway ?? releaseManifestGateway(), currentVersion: appVersion)
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
        diagnostics.useBackgroundInput { [weak self] in self?.input.monitorsBackgroundEvents ?? false }
        hub.$connections
            .sink { [weak self] rows in self?.recorder.observeLinks(rows) }
            .store(in: &cancellables)
        $slots
            .sink { [weak self] slots in self?.recorder.observeSlots(slots) }
            .store(in: &cancellables)
    }

    /// The table and every connection's switches follow the bindings, the
    /// two pools, the global switches and the per-controller ones. The
    /// emitted values are used, not the properties: `@Published` delivers
    /// before the write lands.
    private func observeRoutingTable() {
        let globalSwitches = settings.objectWillChange.afterMutationSettles().map { _ in () }.prepend(())
        let switches = Publishers.CombineLatest(globalSwitches, slotPreferences.statePublisher)
        Publishers.CombineLatest4(hub.$bindings, wifi.$connections, moonlight.$connections, switches)
            .sink { [weak self] bindings, pool, hosts, switches in
                self?.refreshRouting(bindings: bindings, pool: pool, hosts: hosts, preferences: switches.1)
            }
            .store(in: &cancellables)
    }

    /// One fold feeds both the hot path's table and the descriptors: a
    /// changed claim re-sends a live slot's descriptor whole.
    private func refreshRouting(
        bindings: [String: String],
        pool: [String: WifiConnection],
        hosts: [String: MoonlightConnection],
        preferences: [String: SlotPreferences]
    ) {
        let global = settings.flags
        let flags = slotFlags(bindings: bindings, global: global, preferences: preferences)
        routing.table.set(routeSnapshot(bindings: bindings, pool: pool, flags: flags, global: global, moonlight: hosts))
        for conn in pool.values {
            conn.setForwardingFlags(global)
            conn.setSlotFlags(flags)
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
        case let .pairingRequired(server): beginPairing(server)
        case let .failure(failure): report(failure)
        case let .pairingFailed(serverId, failure): reportPairingFailure(serverId: serverId, failure)
        }
    }

    func report(_ failure: ConnectionFailure) {
        lastFailure = failure
        failures.send(failure)
    }

    // MARK: - Slots

    /// Rebuild the slot list and release bindings whose controller is gone;
    /// their memory stays for the pad's return. The catalogs and probes are
    /// read here; the rest arrived with the emission.
    private func rebuildSlots(
        gcSlots: [GameControllerInput.Slot],
        connections: [ConnectionSummary],
        bindings: [String: String],
        facts: SlotFactsSnapshot
    ) {
        hub.keepPresent(Set(gcSlots.map(\.id)))
        var facts = facts
        facts.catalogs = wifi.catalogs
        facts.probes = wifi.capabilities
        facts.moonlightHostTypes = Dictionary(uniqueKeysWithValues: moonlight.rememberedHosts.map { ($0.id, $0.emulatedType) })
        slots = composeSlots(gcSlots: gcSlots, connections: connections, bindings: bindings, facts: facts)
        self.connections = connections
    }
}
