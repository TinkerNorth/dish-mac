// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import XCTest
@testable import DishEngine

/// The engine with the device's IO thread played by the test: the voices
/// open at the device's width and play their lanes into their channels, the
/// microphone captures only while every gate is open, and mute lands within
/// a window.
@MainActor
final class ControllerAudioEngineTests: XCTestCase {

    private var ports: FakeAudioPorts!
    private var engine: ControllerAudioEngine!
    private var connection: WifiConnection!

    override func setUp() {
        super.setUp()
        ports = FakeAudioPorts()
        engine = ControllerAudioEngine(ports: ports)
        let server = DiscoveredServer(name: "Desk", ip: "10.0.0.1", udpPort: 9876, pairPort: 9443, httpPort: 9443, machineId: "desk")
        connection = WifiConnection(id: "desk", server: server)
        connection.attachSlot("slot", controllerType: 0, capabilities: .none)
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

    private func facts(micOn: Bool = true, speakerOn: Bool = true, muted: Bool = false, live: Bool = true) -> AudioFacts {
        AudioFacts(
            routeMic: true,
            routeSpeaker: true,
            routeHapticLanes: true,
            micOn: micOn,
            speakerOn: speakerOn,
            host: HostAudioVerdict(mic: true, speaker: true, hapticAudio: true),
            live: live,
            micPermitted: true,
            muted: muted
        )
    }

    private func binding(_ facts: AudioFacts) -> AudioBinding {
        AudioBinding(slotId: "slot", connection: connection, controllerIndex: 0, route: dualSense, facts: facts)
    }

    private func tone(channels: Int) -> [Float] {
        (0 ..< AudioWire.samplesPerChannel * channels).map { 0.3 * sinf(2 * .pi * 440 * Float($0 / channels) / 48000) }
    }

    private func encodedTone(channels: Int, bitrate: Int) throws -> Data {
        let encoder = try XCTUnwrap(OpusEncoder(channels: channels, bitrate: bitrate))
        return try XCTUnwrap(encoder.encode(tone(channels: channels)))
    }

    private func waitUntil(timeout: TimeInterval = 3, _ predicate: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return predicate()
    }

    private func rms(_ samples: [Float], stride channels: Int, offset: Int) -> Float {
        let picked = Swift.stride(from: offset, to: samples.count, by: channels).map { samples[$0] }
        return sqrtf(picked.reduce(0) { $0 + $1 * $1 } / Float(picked.count))
    }

    // MARK: - The voices

    func testBothVoicesOpenOneOutputAtTheDevicesWidth() {
        engine.apply([binding(facts())])
        XCTAssertEqual(ports.outputs.count, 1)
        XCTAssertEqual(ports.outputs.first?.channels, 4, "the haptics lanes need the DualSense's 4-channel stream")
        XCTAssertEqual(ports.outputs.first?.started, true)
        XCTAssertEqual(engine.state["slot"]?.plan.speakerVoice, true)
        XCTAssertEqual(engine.state["slot"]?.plan.hapticVoice, true)
        engine.apply([binding(facts())])
        XCTAssertEqual(ports.outputs.count, 1, "the same plan again reopens nothing")
    }

    func testTheSpeakerLaneLandsOnChannelsOneAndTwoAndTheHapticsOnThreeAndFour() async throws {
        engine.apply([binding(facts())])
        let output = try XCTUnwrap(ports.outputs.first)
        let speaker = try encodedTone(channels: 2, bitrate: AudioWire.speakerBitrate)
        for seq in UInt16(0) ..< 3 {
            connection.returnPaths.speakerAudio?(AudioFrame(controllerIndex: 0, seq: seq, opus: speaker))
        }
        let decoded = await waitUntil { self.engine.counters(for: "slot")?.speakerPlayed == 3 }
        XCTAssertTrue(decoded)
        let window = output.pull(frames: AudioWire.samplesPerChannel)
        XCTAssertGreaterThan(rms(window, stride: 4, offset: 0), 0.05, "the speaker plays on channel 1")
        XCTAssertGreaterThan(rms(window, stride: 4, offset: 1), 0.05, "and channel 2")
        XCTAssertEqual(rms(window, stride: 4, offset: 2), 0, "the haptics lanes stay silent")
        XCTAssertEqual(rms(window, stride: 4, offset: 3), 0)

        for seq in UInt16(0) ..< 3 {
            connection.returnPaths.hapticAudio?(AudioFrame(controllerIndex: 0, seq: seq, opus: speaker))
        }
        let haptics = await waitUntil { self.engine.counters(for: "slot")?.hapticPlayed == 3 }
        XCTAssertTrue(haptics)
        let second = output.pull(frames: AudioWire.samplesPerChannel)
        XCTAssertGreaterThan(rms(second, stride: 4, offset: 2), 0.05, "the haptics play on channel 3")
        XCTAssertGreaterThan(rms(second, stride: 4, offset: 3), 0.05, "and channel 4")
    }

    func testTwoPadsOnOneSatelliteEachHearTheirOwnIndex() async throws {
        let index = try XCTUnwrap(connection.attachSlot("second", controllerType: 0, capabilities: .none))
        XCTAssertEqual(index, 1)
        let second = AudioBinding(slotId: "second", connection: connection, controllerIndex: index, route: dualSense, facts: facts())
        engine.apply([binding(facts()), second])
        let speaker = try encodedTone(channels: 2, bitrate: AudioWire.speakerBitrate)
        for seq in UInt16(0) ..< 3 {
            connection.returnPaths.speakerAudio?(AudioFrame(controllerIndex: 1, seq: seq, opus: speaker))
        }
        let played = await waitUntil { self.engine.counters(for: "second")?.speakerPlayed == 3 }
        XCTAssertTrue(played, "index 1's lane plays on the pad holding index 1")
        XCTAssertEqual(engine.counters(for: "slot")?.speakerPlayed, 0, "the pad on index 0 hears none of it")

        engine.apply([binding(facts())])
        connection.returnPaths.speakerAudio?(AudioFrame(controllerIndex: 1, seq: 3, opus: speaker))
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(engine.counters(for: "slot")?.speakerPlayed, 0, "a pad that let go leaves its index silent")
    }

    func testTheRingCushionsTwoWindowsBeforePlaying() async throws {
        engine.apply([binding(facts())])
        let output = try XCTUnwrap(ports.outputs.first)
        let speaker = try encodedTone(channels: 2, bitrate: AudioWire.speakerBitrate)
        connection.returnPaths.speakerAudio?(AudioFrame(controllerIndex: 0, seq: 0, opus: speaker))
        let one = await waitUntil { self.engine.counters(for: "slot")?.speakerPlayed == 1 }
        XCTAssertTrue(one)
        XCTAssertEqual(rms(output.pull(frames: AudioWire.samplesPerChannel), stride: 4, offset: 0), 0, "one window is not a cushion")
    }

    func testTheSpeakerSwitchOffClosesTheOutputAndALostFrameIsConcealed() async throws {
        engine.apply([binding(facts())])
        let speaker = try encodedTone(channels: 2, bitrate: AudioWire.speakerBitrate)
        connection.returnPaths.speakerAudio?(AudioFrame(controllerIndex: 0, seq: 0, opus: speaker))
        connection.returnPaths.speakerAudio?(AudioFrame(controllerIndex: 0, seq: 2, opus: speaker))
        connection.returnPaths.speakerAudio?(AudioFrame(controllerIndex: 0, seq: 3, opus: speaker))
        let concealed = await waitUntil { self.engine.counters(for: "slot")?.speakerConcealed == 1 }
        XCTAssertTrue(concealed, "frame 1 never came and 3 proved it lost")
        engine.apply([binding(facts(speakerOn: false))])
        XCTAssertEqual(ports.outputs.first?.started, false)
        XCTAssertEqual(engine.state["slot"]?.plan.speakerVoice, false)
        XCTAssertEqual(engine.state["slot"]?.plan.hapticVoice, false, "the speaker switch covers the lanes")
    }

    /// The satellite starts a slot's lanes over each time it plugs the pad,
    /// and a new session is a new pad too; the old playhead would read every
    /// frame of the new stream as late for as long as the old count ran ahead.
    func testASlotPluggedAgainAndANewConnectionStartTheLanesFresh() async throws {
        connection.attachSlot("slot", controllerType: 0, capabilities: .none)
        engine.apply([binding(facts())])
        let speaker = try encodedTone(channels: 2, bitrate: AudioWire.speakerBitrate)
        let stream = { (conn: WifiConnection) in
            for seq in UInt16(0) ..< 3 {
                conn.returnPaths.speakerAudio?(AudioFrame(controllerIndex: 0, seq: seq, opus: speaker))
            }
        }
        stream(connection)
        let first = await waitUntil { self.engine.counters(for: "slot")?.speakerPlayed == 3 }
        XCTAssertTrue(first)

        stream(connection)
        let replayed = await waitUntil(timeout: 0.3) { self.engine.counters(for: "slot")?.speakerPlayed == 6 }
        XCTAssertFalse(replayed, "the same numbers again are late behind the playhead")

        connection.markSlotApplied("slot")
        stream(connection)
        let pluggedAgain = await waitUntil { self.engine.counters(for: "slot")?.speakerPlayed == 6 }
        XCTAssertTrue(pluggedAgain, "plugged again: the lanes start over")

        let server = DiscoveredServer(name: "Den", ip: "10.0.0.2", udpPort: 9876, pairPort: 9443, httpPort: 9443, machineId: "den")
        let other = WifiConnection(id: "den", server: server)
        engine.apply([AudioBinding(slotId: "slot", connection: other, controllerIndex: 0, route: dualSense, facts: facts())])
        stream(other)
        let newSession = await waitUntil { self.engine.counters(for: "slot")?.speakerPlayed == 9 }
        XCTAssertTrue(newSession, "a new session is a new pad")
    }

    // MARK: - The microphone

    func testTheMicrophoneCapturesOnlyWhileDeliveringAndMuteLandsWithinAWindow() async throws {
        engine.apply([binding(facts())])
        let input = try XCTUnwrap(ports.inputs.first)
        XCTAssertTrue(input.started)
        XCTAssertEqual(input.channels, AudioWire.micChannels)
        input.push(tone(channels: 1))
        let sent = await waitUntil { self.engine.counters(for: "slot")?.micSent == 1 }
        XCTAssertTrue(sent, "a full 20 ms window is encoded and handed to the connection")

        engine.apply([binding(facts(muted: true))])
        XCTAssertTrue(input.started, "muted keeps the microphone armed")
        XCTAssertEqual(engine.state["slot"]?.plan.capture, false)
        input.push(tone(channels: 1))
        input.push(tone(channels: 1))
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(engine.counters(for: "slot")?.micSent, 1, "muted means zero packets")

        engine.apply([binding(facts(muted: false))])
        input.push(tone(channels: 1))
        let resumed = await waitUntil { self.engine.counters(for: "slot")?.micSent == 2 }
        XCTAssertTrue(resumed)
    }

    func testHalfWindowsAccumulateAcrossCallbacks() async throws {
        engine.apply([binding(facts())])
        let input = try XCTUnwrap(ports.inputs.first)
        let half = Array(tone(channels: 1).prefix(AudioWire.samplesPerChannel / 2))
        input.push(half)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(engine.counters(for: "slot")?.micSent, 0, "half a window is not a frame")
        input.push(half)
        let sent = await waitUntil { self.engine.counters(for: "slot")?.micSent == 1 }
        XCTAssertTrue(sent)
    }

    func testTheMicSwitchOffStopsTheInputAndNoPermissionArmsNothing() {
        engine.apply([binding(facts())])
        engine.apply([binding(facts(micOn: false))])
        XCTAssertEqual(ports.inputs.first?.started, false)
        XCTAssertEqual(engine.state["slot"]?.plan.micArmed, false)
        var noPermission = facts()
        noPermission.micPermitted = false
        engine.apply([binding(noPermission)])
        XCTAssertEqual(ports.inputs.count, 1, "no new input is opened without the system's leave")
    }

    // MARK: - The inspector's tests

    func testTheToneOpensTheOutputForItselfAndClosesItWhenNoVoiceIsWanted() async throws {
        engine.apply([binding(facts(live: false))])
        XCTAssertTrue(ports.outputs.isEmpty, "no session, no voice")
        XCTAssertTrue(engine.playTone(for: "slot"))
        XCTAssertFalse(engine.playTone(for: "slot"), "one tone at a time")
        let output = try XCTUnwrap(ports.outputs.first)
        XCTAssertTrue(output.started)
        XCTAssertEqual(engine.state["slot"]?.tonePlaying, true)
        let swept = await waitUntil(timeout: 3) { self.engine.counters(for: "slot")?.toneWindows == TestTone.windows }
        XCTAssertTrue(swept, "forty windows, one every 20 ms")
        let window = output.pull(frames: AudioWire.samplesPerChannel)
        XCTAssertGreaterThan(rms(window, stride: 4, offset: 0), 0.1, "the tone rides the speaker pair")
        XCTAssertEqual(rms(window, stride: 4, offset: 2), 0, "and never the haptics lanes")
        let closed = await waitUntil { self.engine.state["slot"]?.tonePlaying == false }
        XCTAssertTrue(closed)
        XCTAssertFalse(output.started, "nothing else wanted the output")
    }

    func testTheToneNeedsASpeakerRoute() {
        engine.apply([AudioBinding(slotId: "slot", connection: connection, controllerIndex: 0, route: nil, facts: facts())])
        XCTAssertFalse(engine.playTone(for: "slot"))
        XCTAssertFalse(engine.playTone(for: "nobody"))
    }

    func testTheMicMeterListensWithoutSendingAndStopsOnItsOwn() async throws {
        let short = ControllerAudioEngine(ports: ports, meterMs: 300)
        short.apply([binding(facts(live: false))])
        XCTAssertTrue(ports.inputs.isEmpty, "no session, no capture")
        XCTAssertTrue(short.startMicMeter(for: "slot"))
        XCTAssertFalse(short.startMicMeter(for: "slot"), "one meter at a time")
        let input = try XCTUnwrap(ports.inputs.first)
        XCTAssertTrue(input.started)
        input.push(tone(channels: 1))
        let metered = await waitUntil { short.state["slot"]?.micMeter?.peakPercent == 30 }
        XCTAssertTrue(metered, "a 0.3 tone peaks at 30%")
        XCTAssertEqual(short.state["slot"]?.micMeter?.levelPercent, 21)
        XCTAssertEqual(short.counters(for: "slot")?.micSent, 0, "the meter sends nothing")
        let stopped = await waitUntil { short.state["slot"]?.micMeter == nil }
        XCTAssertTrue(stopped, "the meter stops on its own")
        XCTAssertFalse(input.started, "nothing else wanted the microphone")
    }

    func testTheMicMeterNeedsAMicRouteAndTheSystemsLeave() {
        var refused = facts(live: false)
        refused.micPermitted = false
        engine.apply([binding(refused)])
        XCTAssertFalse(engine.startMicMeter(for: "slot"))
        engine.apply([AudioBinding(slotId: "slot", connection: connection, controllerIndex: 0, route: nil, facts: facts())])
        XCTAssertFalse(engine.startMicMeter(for: "slot"))
        engine.stopMicMeter(for: "slot")
        XCTAssertEqual(engine.state["slot"]?.micMeter, nil)
    }

    // MARK: - Lifecycle

    func testARestingSessionOpensNothingAndARemovedBindingClosesEverything() {
        engine.apply([binding(facts(live: false))])
        XCTAssertEqual(ports.outputs.count, 0)
        XCTAssertEqual(ports.inputs.count, 0)
        XCTAssertEqual(engine.state["slot"]?.plan.capMic, true, "the caps are still the descriptor's business")
        engine.apply([binding(facts())])
        engine.apply([])
        XCTAssertEqual(ports.outputs.first?.started, false)
        XCTAssertEqual(ports.inputs.first?.started, false)
        XCTAssertEqual(engine.state, [:])
    }

    func testTheLampWordReachesTheState() async {
        engine.apply([binding(facts())])
        connection.returnPaths.micLed?(MicLedCommand(controllerIndex: 0, state: .pulse))
        let lit = await waitUntil { self.engine.state["slot"]?.micLed == .pulse }
        XCTAssertTrue(lit)
    }
}
