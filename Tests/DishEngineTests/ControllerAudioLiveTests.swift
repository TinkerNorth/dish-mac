// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// Controller audio against the fake satellite: the descriptor advertises
// the audio caps the switches allow, the microphone's frames reach the
// satellite with one monotonic sequence across a mute, and the satellite's
// speaker frames reach the engine.

import Combine
import DishCore
import XCTest
@testable import DishEngine

@MainActor
final class ControllerAudioLiveTests: XCTestCase {

    private var satellite: FakeSatellite!
    private var ports: FakeSatellite.Ports!
    private var defaults: UserDefaults!
    private var defaultsName: String!
    private var store: ConnectionStore!
    private var manager: WifiConnectionManager!
    private var hub: ConnectionHub!
    private var audioPorts: FakeAudioPorts!
    private var engine: ControllerAudioEngine!

    override func setUpWithError() throws {
        try super.setUpWithError()
        satellite = try FakeSatellite()
        ports = try satellite.start()
        try satellite.requireHTTPSTransport()
        defaultsName = "dish.test.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsName)
        store = ConnectionStore(defaults: defaults, keyStore: InMemoryKeyStore())
        manager = WifiConnectionManager(store: store)
        hub = ConnectionHub(wifi: manager, store: store)
        audioPorts = FakeAudioPorts()
        engine = ControllerAudioEngine(ports: audioPorts)
        let keyHex = String(repeating: "1f", count: 32)
        satellite.pairingKeyHex = keyHex
        store.setSharedKey(keyHex, for: server.id)
    }

    override func tearDown() {
        engine.apply([])
        for id in manager.connections.keys {
            manager.disconnect(id: id)
        }
        satellite.stop()
        defaults.removePersistentDomain(forName: defaultsName)
        super.tearDown()
    }

    private var server: DiscoveredServer {
        DiscoveredServer(
            name: "Fake",
            ip: "127.0.0.1",
            udpPort: Int(ports.udp),
            pairPort: Int(ports.rest),
            httpPort: Int(ports.rest),
            machineId: satellite.machineId
        )
    }

    private var dualSense: PadAudioFunction {
        PadAudioFunction(
            device: AudioDeviceFacts(
                id: 7,
                uid: "ds",
                name: "DualSense Wireless Controller",
                isUSB: true,
                inputChannels: 1,
                outputChannels: 4
            ),
            family: .dualSense
        )
    }

    private func facts(muted: Bool = false) -> AudioFacts {
        AudioFacts(
            routeMic: true,
            routeSpeaker: true,
            routeHapticLanes: true,
            micOn: true,
            speakerOn: true,
            host: HostAudioVerdict(mic: true, speaker: true, hapticAudio: true),
            live: true,
            micPermitted: true,
            muted: muted
        )
    }

    private var claimedCaps: [String: Any] {
        satellite.appliedControllers.first?["caps"] as? [String: Any] ?? [:]
    }

    private func waitUntil(timeout: TimeInterval = 8, _ predicate: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return predicate()
    }

    private func tone() -> [Float] {
        (0 ..< AudioWire.samplesPerChannel).map { 0.3 * sinf(2 * .pi * 440 * Float($0) / 48000) }
    }

    private func bindAndGoLive() async throws -> WifiConnection {
        let conn = WifiConnection(id: server.id, server: server)
        manager.register(conn)
        let caps = ControllerCapabilities(hasMotion: true, hasRumble: true).withAudio(dualSense)
        hub.bind(slotId: "slot-a", connectionId: server.id, capabilities: caps, family: .dualSense)
        manager.applyForwardingFlags(ForwardingFlags(mic: true, speaker: true), to: server.id)
        manager.connect(to: server)
        let live = await waitUntil { conn.state == .live && !self.claimedCaps.isEmpty }
        XCTAssertTrue(live)
        return conn
    }

    func testTheDescriptorAdvertisesTheAudioCapsTheSwitchesAllow() async throws {
        _ = try await bindAndGoLive()
        XCTAssertEqual(claimedCaps["mic"] as? Bool, true)
        XCTAssertEqual(claimedCaps["speaker"] as? Bool, true)
        XCTAssertEqual(claimedCaps["hapticAudio"] as? Bool, true)
        manager.applyForwardingFlags(ForwardingFlags(mic: false, speaker: false), to: server.id)
        let withdrawn = await waitUntil { self.claimedCaps["mic"] as? Bool == false && self.claimedCaps["hapticAudio"] as? Bool == false }
        XCTAssertTrue(withdrawn, "a switched-off audio feature is no longer claimed")
    }

    func testMicFramesReachTheSatelliteWithOneSequenceAcrossAMute() async throws {
        let conn = try await bindAndGoLive()
        engine.apply([AudioBinding(slotId: "slot-a", connection: conn, controllerIndex: 0, route: dualSense, facts: facts())])
        let input = try XCTUnwrap(audioPorts.inputs.first)
        for _ in 0 ..< 3 {
            input.push(tone())
        }
        let arrived = await waitUntil { self.satellite.micFrames.count == 3 }
        XCTAssertTrue(arrived, "three windows, three frames")
        XCTAssertEqual(satellite.micFrames.map(\.seq), [0, 1, 2])
        XCTAssertTrue(satellite.micFrames.allSatisfy { !$0.opus.isEmpty })

        engine.apply([AudioBinding(slotId: "slot-a", connection: conn, controllerIndex: 0, route: dualSense, facts: facts(muted: true))])
        input.push(tone())
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(satellite.micFrames.count, 3, "muted means zero packets on the wire")

        engine.apply([AudioBinding(slotId: "slot-a", connection: conn, controllerIndex: 0, route: dualSense, facts: facts())])
        input.push(tone())
        let resumed = await waitUntil { self.satellite.micFrames.count == 4 }
        XCTAssertTrue(resumed)
        XCTAssertEqual(satellite.micFrames.last?.seq, 3, "the sequence never restarts")
    }

    func testTheSatellitesSpeakerFramesReachTheEngine() async throws {
        let conn = try await bindAndGoLive()
        engine.apply([AudioBinding(slotId: "slot-a", connection: conn, controllerIndex: 0, route: dualSense, facts: facts())])
        XCTAssertTrue(satellite.awaitHeartbeats(atLeast: 1), "the reply path is learned from the first uplink frame")
        let encoder = try XCTUnwrap(OpusEncoder(channels: 2, bitrate: AudioWire.speakerBitrate))
        let packet = try XCTUnwrap(encoder
            .encode((0 ..< AudioWire.samplesPerChannel * 2).map { 0.3 * sinf(2 * .pi * 440 * Float($0 / 2) / 48000) }))
        for seq in UInt16(0) ..< 3 {
            XCTAssertTrue(satellite.injectSpeakerAudio(ctrlIdx: 0, seq: seq, opus: packet))
        }
        let played = await waitUntil { self.engine.counters(for: "slot-a")?.speakerPlayed == 3 }
        XCTAssertTrue(played, "the frames came down the wire, through the window and the decoder")
        XCTAssertTrue(satellite.injectHapticAudio(ctrlIdx: 0, seq: 0, opus: packet))
        let haptic = await waitUntil { self.engine.counters(for: "slot-a")?.hapticPlayed == 1 }
        XCTAssertTrue(haptic)
        XCTAssertTrue(satellite.injectMicLed(ctrlIdx: 0, state: 1))
        let lamp = await waitUntil { self.engine.state["slot-a"]?.micLed == .on }
        XCTAssertTrue(lamp)
    }

    /// The whole pipeline against the satellite: the pad routed, its mic
    /// switch on, the session live and the host's leave given, the
    /// microphone arms and delivers; the chip mutes everything at once and
    /// the word goes with the session.
    func testThePipelineArmsTheMicrophoneOnceLiveAndTheChipMutesIt() async throws {
        satellite.controllerAudioEnabled = true
        let input = GameControllerInput()
        let preferences = SlotPreferenceStore(defaults: defaults)
        let functions = PadAudioFunctionSource(read: { [self.dualSense.device] })
        let permission = MicPermissionGate(read: { true }, ask: { $0(true) })
        let dependencies = AudioDependencies(ports: audioPorts, functions: functions, permission: permission)
        let pipeline = AudioPipeline(hub: hub, wifi: manager, input: input, slotPreferences: preferences, dependencies: dependencies)
        pipeline.start()
        input.slots = [GameControllerInput.Slot(
            id: "slot-a",
            name: "DualSense",
            capabilities: ControllerCapabilities(hasRumble: true),
            family: .dualSense
        )]
        preferences.setMic(true, for: "slot-a")
        let conn = WifiConnection(id: server.id, server: server)
        manager.register(conn)
        let caps = ControllerCapabilities(hasRumble: true).withAudio(dualSense)
        hub.bind(slotId: "slot-a", connectionId: server.id, capabilities: caps, family: .dualSense)
        manager.applyForwardingFlags(ForwardingFlags(mic: true, speaker: true), to: server.id)
        manager.connect(to: server)
        let armed = await waitUntil { pipeline.engine.state["slot-a"]?.plan.micArmed == true }
        XCTAssertTrue(armed, "live, routed, switched on, permitted and granted by the host")
        XCTAssertEqual(pipeline.indicator.state, .live)
        XCTAssertEqual(pipeline.engine.state["slot-a"]?.plan.hapticVoice, true, "the host grants the lanes too")
        XCTAssertEqual(claimedCaps["mic"] as? Bool, true)
        let mic = try XCTUnwrap(audioPorts.inputs.first)
        mic.push(tone())
        let arrived = await waitUntil { self.satellite.micFrames.count == 1 }
        XCTAssertTrue(arrived)

        pipeline.toggleAllMics()
        XCTAssertEqual(pipeline.indicator.state, .muted)
        XCTAssertEqual(pipeline.engine.state["slot-a"]?.plan.capture, false)
        pipeline.toggleAllMics()
        XCTAssertEqual(pipeline.indicator.state, .live)

        manager.disconnect(id: server.id)
        let hidden = await waitUntil { pipeline.indicator.state == .hidden }
        XCTAssertTrue(hidden, "no session, no microphone")
    }

    /// The largest packet the datagram ceiling allows must arrive whole: a
    /// receive buffer shorter than the ceiling truncates it and the AEAD
    /// then rejects every full-size frame.
    func testAFrameAtTheDatagramCeilingArrivesWhole() async throws {
        let conn = try await bindAndGoLive()
        engine.apply([AudioBinding(slotId: "slot-a", connection: conn, controllerIndex: 0, route: dualSense, facts: facts())])
        XCTAssertTrue(satellite.awaitHeartbeats(atLeast: 1))
        let largest = ProtocolConstants.udpMaxInnerPayloadBytes - AudioWire.headerBytes
        let packet = Data((0 ..< largest).map { UInt8(truncatingIfNeeded: $0) })
        XCTAssertTrue(satellite.injectSpeakerAudio(ctrlIdx: 0, seq: 0, opus: packet))
        let arrived = await waitUntil { self.engine.counters(for: "slot-a")?.speakerPlayed == 1 }
        XCTAssertTrue(arrived, "a frame of \(largest) Opus bytes crossed the wire whole")
    }
}
