// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import XCTest
@testable import DishEngine

/// The folds behind the audio pipeline, and the pipeline itself over fake
/// ports: every pad gets a route, a bound pad's facts reach the engine and
/// its descriptor claims follow the route, the gates flip the plan, and a
/// pad that leaves takes its mute with it.
@MainActor
final class AudioPipelineTests: XCTestCase {

    private let device = AudioDeviceFacts(
        id: 9,
        uid: "ds",
        name: "DualSense Wireless Controller",
        isUSB: true,
        inputChannels: 1,
        outputChannels: 4
    )

    private var function: PadAudioFunction {
        PadAudioFunction(device: device, family: .dualSense)
    }

    private func pad(_ id: String, family: PadFamily = .dualSense) -> GameControllerInput.Slot {
        GameControllerInput.Slot(id: id, name: "Pad", capabilities: ControllerCapabilities(hasRumble: true), family: family)
    }

    private func connection(_ id: String) -> WifiConnection {
        let server = DiscoveredServer(name: id, ip: "10.0.0.1", udpPort: 9876, pairPort: 9443, httpPort: 9443, machineId: id)
        return WifiConnection(id: id, server: server)
    }

    private func waitUntil(timeout: TimeInterval = 3, _ predicate: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return predicate()
    }

    // MARK: - The folds

    func testEveryPadGetsARouteAndOnlyAPlayStationPadAFunction() {
        let routes = audioRoutes(pads: [pad("ds"), pad("xb", family: .xbox)], functions: [function])
        XCTAssertEqual(routes["ds"], PadAudioRoute(verdict: .routed, function: function))
        XCTAssertEqual(routes["xb"], PadAudioRoute(verdict: .familyWithoutAudio, function: nil))
    }

    func testTheFactsReadTheRouteTheSwitchesAndTheGates() {
        let bare = audioFacts(route: nil, preferences: SlotPreferences(), host: .none, live: false, permitted: false, muted: false)
        XCTAssertFalse(bare.routeMic)
        XCTAssertFalse(bare.routeSpeaker)
        XCTAssertFalse(bare.routeHapticLanes)
        XCTAssertFalse(bare.micOn, "the mic is off until asked")
        XCTAssertTrue(bare.speakerOn, "the speaker is on until refused")
        XCTAssertFalse(bare.micPermitted)

        var preferences = SlotPreferences()
        preferences.mic = true
        preferences.speaker = false
        let host = HostAudioVerdict(mic: true, speaker: false, hapticAudio: true)
        let route = PadAudioRoute(verdict: .routed, function: function)
        let full = audioFacts(route: route, preferences: preferences, host: host, live: true, permitted: true, muted: true)
        XCTAssertTrue(full.routeMic)
        XCTAssertTrue(full.routeSpeaker)
        XCTAssertTrue(full.routeHapticLanes)
        XCTAssertTrue(full.micOn)
        XCTAssertFalse(full.speakerOn)
        XCTAssertEqual(full.host, host)
        XCTAssertTrue(full.live)
        XCTAssertTrue(full.micPermitted)
        XCTAssertTrue(full.muted)
    }

    private func armedPlan(muted: Bool) -> ControllerAudioState {
        let host = HostAudioVerdict(mic: true, speaker: false, hapticAudio: false)
        let facts = AudioFacts(routeMic: true, micOn: true, host: host, live: true, micPermitted: true, muted: muted)
        return ControllerAudioState(plan: audioPlan(facts))
    }

    func testTheIndicatorCountsArmedAndDeliveringMicrophones() {
        XCTAssertEqual(micIndicatorState([:]), .hidden)
        XCTAssertEqual(micIndicatorState(["a": ControllerAudioState()]), .hidden, "a silent plan arms nothing")
        XCTAssertEqual(micIndicatorState(["a": armedPlan(muted: false)]), .live)
        XCTAssertEqual(micIndicatorState(["a": armedPlan(muted: true)]), .muted)
        XCTAssertEqual(micIndicatorState(["a": armedPlan(muted: true), "b": armedPlan(muted: false)]), .live, "one live mic is live")
    }

    func testTheBindingsFollowThePoolInSlotOrder() {
        let desk = connection("desk")
        let den = connection("den")
        var preferences = SlotPreferences()
        preferences.mic = true
        let bindings = audioBindings(
            bindings: ["b": "den", "a": "desk", "c": "gone"],
            pool: ["desk": desk, "den": den],
            routes: ["a": PadAudioRoute(verdict: .routed, function: function)],
            preferences: ["a": preferences],
            mutes: ["a"],
            permitted: true
        )
        XCTAssertEqual(bindings.map(\.slotId), ["a", "b"], "a binding whose connection left the pool is dropped")
        XCTAssertTrue(bindings.first?.connection === desk)
        XCTAssertEqual(bindings.first?.route, function)
        XCTAssertEqual(bindings.first?.facts.micOn, true)
        XCTAssertEqual(bindings.first?.facts.muted, true)
        XCTAssertEqual(bindings.first?.facts.live, false, "an idle connection is not live")
        XCTAssertEqual(bindings.first?.facts.host, HostAudioVerdict.none, "no probe yet")
        XCTAssertNil(bindings.last?.route)
        XCTAssertEqual(bindings.last?.facts.muted, false)
    }

    // MARK: - The pipeline

    func testThePipelineRoutesTheBoundPadFollowsTheSwitchesAndClaimsTheMic() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "dish.test.\(UUID().uuidString)"))
        let store = ConnectionStore(defaults: defaults, keyStore: InMemoryKeyStore())
        let wifi = WifiConnectionManager(store: store)
        let hub = ConnectionHub(wifi: wifi, store: store)
        let input = GameControllerInput()
        let preferences = SlotPreferenceStore(defaults: defaults)
        let ports = FakeAudioPorts()
        var asked = 0
        let permission = MicPermissionGate(read: { false }, ask: { completion in
            asked += 1
            completion(true)
        })
        let dependencies = AudioDependencies(
            ports: ports,
            functions: PadAudioFunctionSource(read: { [self.device] }),
            permission: permission
        )
        let pipeline = AudioPipeline(hub: hub, wifi: wifi, input: input, slotPreferences: preferences, dependencies: dependencies)
        pipeline.start()
        input.slots = [pad("ds")]
        XCTAssertEqual(pipeline.routes.state["ds"]?.verdict, .routed)

        let desk = connection("desk")
        wifi.register(desk)
        hub.bind(slotId: "ds", connectionId: "desk", capabilities: ControllerCapabilities(hasRumble: true), family: .dualSense)
        wifi.applyForwardingFlags(ForwardingFlags(mic: true, speaker: true), to: "desk")
        XCTAssertEqual(pipeline.engine.state["ds"]?.plan.capSpeaker, true)
        XCTAssertEqual(pipeline.engine.state["ds"]?.plan.capMic, false, "the mic is off until asked")
        XCTAssertEqual(pipeline.engine.state["ds"]?.plan.speakerVoice, false, "no session, no voice")
        XCTAssertTrue(ports.outputs.isEmpty)
        XCTAssertEqual(pipeline.indicator.state, .hidden)

        preferences.setMic(true, for: "ds")
        XCTAssertEqual(pipeline.engine.state["ds"]?.plan.capMic, true)
        let claimed = await waitUntil { desk.desiredDescriptor.map { $0.caps & ProtocolConstants.capMic != 0 } == true }
        XCTAssertTrue(claimed, "the bound pad's descriptor claims the mic once its route and switch allow")

        pipeline.requestMicrophoneLeave()
        XCTAssertEqual(asked, 1, "the system is asked while it has not answered")
        let granted = await waitUntil { permission.state }
        XCTAssertTrue(granted)

        pipeline.mutes.setMuted(true, for: "ds")
        XCTAssertEqual(pipeline.engine.state["ds"]?.plan.capture, false)
        input.slots = []
        XCTAssertEqual(pipeline.mutes.state, [], "a pad that left takes its mute with it")
        XCTAssertEqual(pipeline.engine.state["ds"]?.plan.capMic, false, "without the pad there is no route")
        defaults.removePersistentDomain(forName: "dish.test")
    }
}
