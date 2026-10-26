// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Combine
import DishCore
import DishKernel
import Foundation

/// What the audio pipeline takes from the system, replaceable in tests.
struct AudioDependencies {
    var ports: AudioPortFactory
    var functions: PadAudioFunctionSource
    var permission: MicPermissionGate

    @MainActor
    static func live() -> AudioDependencies {
        AudioDependencies(ports: CoreAudioPorts(), functions: PadAudioFunctionSource(), permission: MicPermissionGate())
    }
}

/// Controller audio wired to the app, built once by `AppModel`: the pads'
/// USB audio functions become a route per slot, every bound slot's facts
/// fold into the bindings the engine applies, a bound pad's descriptor
/// claims follow its route, and the app-wide microphone word is derived
/// from the engine's state. Nothing here is started; the owner starts it.
@MainActor
final class AudioPipeline {

    /// The USB audio functions of the pads the system sees.
    let functions: PadAudioFunctionSource
    /// The controllers whose microphone the user muted, in memory only.
    let mutes = MicMuteStore()
    /// The system's leave to capture a microphone.
    let permission: MicPermissionGate
    let engine: ControllerAudioEngine
    /// Every pad's route, bound or not, keyed by slot id.
    let routes: Composer<[String: PadAudioRoute]>
    /// The app-wide microphone word, from every bound controller's plan.
    let indicator: Composer<MicIndicatorState>

    private let hub: ConnectionHub
    private let input: GameControllerInput
    private var cancellables = Set<AnyCancellable>()

    init(
        hub: ConnectionHub,
        wifi: WifiConnectionManager,
        input: GameControllerInput,
        slotPreferences: SlotPreferenceStore,
        dependencies: AudioDependencies
    ) {
        self.hub = hub
        self.input = input
        functions = dependencies.functions
        permission = dependencies.permission
        engine = ControllerAudioEngine(ports: dependencies.ports)
        routes = Composer(input.$slots, functions.statePublisher, initial: [:], transform: audioRoutes)
        indicator = Composer(engine.statePublisher, initial: .hidden, transform: micIndicatorState)
        observeBindings(wifi: wifi, slotPreferences: slotPreferences)
        observeClaims()
        observeDepartures()
    }

    /// Starts following the audio device list and re-reads the permission.
    func start() {
        functions.start()
        permission.refresh()
    }

    /// A controller's mic switched on asks the system once while it has not
    /// answered; a refusal reads back through the permission chip.
    func requestMicrophoneLeave() {
        permission.refresh()
        if !permission.state { permission.request() }
    }

    /// One pad's audio for the Diagnostics window.
    func padDiagnostics(_ slotId: String) -> PadAudioDiagnostics {
        PadAudioDiagnostics(route: routes.state[slotId], state: engine.state[slotId], counters: engine.counters(for: slotId))
    }

    /// The chip's one action: every live microphone mutes together, every
    /// muted one comes back together.
    func toggleAllMics() {
        let armed = engine.state.filter(\.value.plan.micArmed).map(\.key)
        switch micToggleAll(indicator.state) {
        case .muteAll: mutes.setMuted(true, for: armed)
        case .unmuteAll: mutes.setMuted(false, for: armed)
        case .nothing: break
        }
    }

    /// The engine follows the bindings, the pool, the routes, the switches,
    /// the mutes and the permission; the summaries are the trigger for a
    /// session or a host verdict that changed. The emitted values are used,
    /// not the properties: `@Published` delivers before the write lands.
    private func observeBindings(wifi: WifiConnectionManager, slotPreferences: SlotPreferenceStore) {
        let gates = Publishers.CombineLatest3(slotPreferences.statePublisher, mutes.statePublisher, permission.statePublisher)
        let triggers = Publishers.CombineLatest(hub.$connections, gates)
        Publishers.CombineLatest4(hub.$bindings, wifi.$connections, routes.statePublisher, triggers)
            .sink { [weak self] bindings, pool, routes, rest in
                let (preferences, mutes, permitted) = rest.1
                self?.engine.apply(
                    audioBindings(
                        bindings: bindings,
                        pool: pool,
                        routes: routes,
                        preferences: preferences,
                        mutes: mutes,
                        permitted: permitted
                    )
                )
            }
            .store(in: &cancellables)
    }

    /// A bound pad's claims follow its route, so the audio caps land when
    /// the pad's USB audio enumerates after its HID did. Settled, so the
    /// hub's bindings already hold the emitted value.
    private func observeClaims() {
        Publishers.CombineLatest3(input.$slots, routes.statePublisher, hub.$bindings)
            .afterMutationSettles()
            .sink { [weak self] pads, routes, bindings in
                guard let self else { return }
                for pad in pads where bindings[pad.id] != nil {
                    hub.setCapabilities(slotId: pad.id, pad.capabilities.withAudio(routes[pad.id]?.function))
                }
            }
            .store(in: &cancellables)
    }

    /// A pad that left takes its mute with it.
    private func observeDepartures() {
        input.$slots
            .sink { [weak self] pads in self?.mutes.retainOnly(Set(pads.map(\.id))) }
            .store(in: &cancellables)
    }
}

/// Every pad's route from the functions the system sees.
func audioRoutes(pads: [GameControllerInput.Slot], functions: [PadAudioFunction]) -> [String: PadAudioRoute] {
    padAudioRoutes(pads: pads.map { AudioRouteCandidate(slotId: $0.id, family: $0.family) }, functions: functions)
}

/// One bound controller's audio facts: its route, its own switches, the
/// host's verdict and the session, the system's leave and the mute.
func audioFacts(
    route: PadAudioRoute?,
    preferences: SlotPreferences,
    host: HostAudioVerdict,
    live: Bool,
    permitted: Bool,
    muted: Bool
) -> AudioFacts {
    AudioFacts(
        routeMic: route?.function?.hasMic ?? false,
        routeSpeaker: route?.function?.hasSpeaker ?? false,
        routeHapticLanes: route?.function?.hasHapticLanes ?? false,
        micOn: preferences.mic,
        speakerOn: preferences.speaker,
        host: host,
        live: live,
        micPermitted: permitted,
        muted: muted
    )
}

/// The engine's bindings: every bound slot its satellite carries, on the
/// controller index it holds there, in slot order.
@MainActor
func audioBindings(
    bindings: [String: String],
    pool: [String: WifiConnection],
    routes: [String: PadAudioRoute],
    preferences: [String: SlotPreferences],
    mutes: Set<String>,
    permitted: Bool
) -> [AudioBinding] {
    bindings.compactMap { slotId, connectionId -> AudioBinding? in
        guard let conn = pool[connectionId], let index = conn.controllerIndex(of: slotId) else { return nil }
        let facts = audioFacts(
            route: routes[slotId],
            preferences: preferences[slotId] ?? SlotPreferences(),
            host: conn.hostAudio,
            live: conn.hasLiveSession,
            permitted: permitted,
            muted: mutes.contains(slotId)
        )
        return AudioBinding(slotId: slotId, connection: conn, controllerIndex: index, route: routes[slotId]?.function, facts: facts)
    }
    .sorted { $0.slotId < $1.slotId }
}

/// The app-wide word: how many microphones are armed and how many deliver.
func micIndicatorState(_ states: [String: ControllerAudioState]) -> MicIndicatorState {
    let plans = states.values.map(\.plan)
    return micIndicator(armed: plans.filter(\.micArmed).count, delivering: plans.filter(\.capture).count)
}
