// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import XCTest
@testable import DishEngine

/// The inspector's tests on the engine: the tone on the speaker pair or the
/// haptics lanes and the microphone meter, each telling its end once, on a
/// pad a host carries or none does; a test cut short tells nothing.
extension ControllerAudioEngineTests {

    /// Counts the ends a test reports.
    final class Ends {
        var count = 0

        func ended() {
            count += 1
        }
    }

    func testTheToneOpensTheOutputForItselfAndClosesItWhenNoVoiceIsWanted() async throws {
        engine.apply([binding(facts(live: false))])
        XCTAssertTrue(ports.outputs.isEmpty, "no session, no voice")
        let ends = Ends()
        XCTAssertTrue(engine.playTone(for: "slot", on: .speaker, ended: ends.ended))
        XCTAssertFalse(engine.playTone(for: "slot", on: .speaker, ended: ends.ended), "one tone at a time")
        let output = try XCTUnwrap(ports.outputs.first)
        XCTAssertTrue(output.started)
        XCTAssertEqual(engine.state["slot"]?.tone, .speaker)
        let swept = await waitUntil(timeout: 3) { self.engine.counters(for: "slot")?.toneWindows == TestTone.windows }
        XCTAssertTrue(swept, "forty windows, one every 20 ms")
        let window = output.pull(frames: AudioWire.samplesPerChannel)
        XCTAssertGreaterThan(rms(window, stride: 4, offset: 0), 0.1, "the tone rides the speaker pair")
        XCTAssertEqual(rms(window, stride: 4, offset: 2), 0, "and never the haptics lanes")
        let closed = await waitUntil { self.engine.state["slot"]?.tone == nil }
        XCTAssertTrue(closed)
        XCTAssertFalse(output.started, "nothing else wanted the output")
        XCTAssertEqual(ends.count, 1, "the end is told once, after the tone played out")
    }

    func testTheHapticsToneRidesTheHapticsLanesAndNeverTheSpeaker() async throws {
        engine.apply([binding(facts(live: false))])
        let ends = Ends()
        XCTAssertTrue(engine.playTone(for: "slot", on: .haptics, ended: ends.ended))
        XCTAssertFalse(engine.playTone(for: "slot", on: .speaker, ended: ends.ended), "one tone at a time, whichever lane")
        XCTAssertEqual(engine.state["slot"]?.tone, .haptics)
        let output = try XCTUnwrap(ports.outputs.first)
        XCTAssertEqual(output.channels, 4, "the device's own width")
        let swept = await waitUntil(timeout: 3) { self.engine.counters(for: "slot")?.toneWindows == TestTone.windows }
        XCTAssertTrue(swept)
        let window = output.pull(frames: AudioWire.samplesPerChannel)
        XCTAssertGreaterThan(rms(window, stride: 4, offset: 2), 0.1, "the tone rides the haptics lanes")
        XCTAssertEqual(rms(window, stride: 4, offset: 0), 0, "and never the speaker pair")
        let ended = await waitUntil { ends.count == 1 }
        XCTAssertTrue(ended)
    }

    func testEachToneNeedsItsLanesRoute() {
        engine.apply([AudioBinding(slotId: "slot", connection: connection, controllerIndex: 0, route: nil, facts: facts())])
        XCTAssertFalse(engine.playTone(for: "slot", on: .speaker, ended: {}))
        XCTAssertFalse(engine.playTone(for: "nobody", on: .speaker, ended: {}))
        let headset = PadAudioFunction(
            device: AudioDeviceFacts(id: 8, uid: "ds4", name: "Wireless Controller", isUSB: true, inputChannels: 1, outputChannels: 2),
            family: .dualShock4
        )
        engine.apply([AudioBinding(slotId: "slot", connection: connection, controllerIndex: 0, route: headset, facts: facts())])
        XCTAssertFalse(engine.playTone(for: "slot", on: .haptics, ended: {}), "a DualShock 4 has no haptics lanes")
        XCTAssertNil(engine.state["slot"]?.tone)
    }

    func testAPadNoHostCarriesStillPlaysTheToneAndListens() async throws {
        let short = ControllerAudioEngine(ports: ports, meterMs: 300)
        var hostless = facts(live: false)
        hostless.host = .none
        short.apply([AudioBinding(slotId: "slot", connection: nil, controllerIndex: 0, route: dualSense, facts: hostless)])
        XCTAssertEqual(short.state["slot"]?.plan, AudioPlan.silent, "no host, no voice and no claim")
        XCTAssertTrue(short.playTone(for: "slot", on: .speaker, ended: {}))
        XCTAssertEqual(ports.outputs.first?.started, true)
        XCTAssertTrue(short.startMicMeter(for: "slot", ended: {}))
        let input = try XCTUnwrap(ports.inputs.first)
        input.push(tone(channels: 1))
        let metered = await waitUntil { short.state["slot"]?.micMeter?.peakPercent == 30 }
        XCTAssertTrue(metered)
        XCTAssertEqual(short.counters(for: "slot")?.micSent, 0, "nowhere to send")
    }

    func testTheMicMeterListensWithoutSendingAndStopsOnItsOwn() async throws {
        let short = ControllerAudioEngine(ports: ports, meterMs: 300)
        short.apply([binding(facts(live: false))])
        XCTAssertTrue(ports.inputs.isEmpty, "no session, no capture")
        let ends = Ends()
        XCTAssertTrue(short.startMicMeter(for: "slot", ended: ends.ended))
        XCTAssertFalse(short.startMicMeter(for: "slot", ended: ends.ended), "one meter at a time")
        let input = try XCTUnwrap(ports.inputs.first)
        XCTAssertTrue(input.started)
        input.push(tone(channels: 1))
        let metered = await waitUntil { short.state["slot"]?.micMeter?.peakPercent == 30 }
        XCTAssertTrue(metered, "a 0.3 tone peaks at 30%")
        XCTAssertEqual(short.state["slot"]?.micMeter?.levelPercent, 21)
        XCTAssertEqual(short.counters(for: "slot")?.micSent, 0, "the meter sends nothing")
        XCTAssertEqual(ends.count, 0)
        let stopped = await waitUntil { short.state["slot"]?.micMeter == nil }
        XCTAssertTrue(stopped, "the meter stops on its own")
        XCTAssertFalse(input.started, "nothing else wanted the microphone")
        XCTAssertEqual(ends.count, 1, "and tells its end once")
    }

    func testStoppingTheMeterEndsItsTestOnce() {
        engine.apply([binding(facts(live: false))])
        let ends = Ends()
        XCTAssertTrue(engine.startMicMeter(for: "slot", ended: ends.ended))
        engine.stopMicMeter(for: "slot")
        engine.stopMicMeter(for: "slot")
        XCTAssertEqual(ends.count, 1)
    }

    func testAPadWhoseAudioGoesMidTestEndsNothing() {
        engine.apply([binding(facts(live: false))])
        let ends = Ends()
        XCTAssertTrue(engine.playTone(for: "slot", on: .speaker, ended: ends.ended))
        XCTAssertTrue(engine.startMicMeter(for: "slot", ended: ends.ended))
        engine.apply([])
        XCTAssertEqual(ends.count, 0, "a test cut short asks nothing")
    }

    func testTheMicMeterNeedsAMicRouteAndTheSystemsLeave() {
        var refused = facts(live: false)
        refused.micPermitted = false
        engine.apply([binding(refused)])
        XCTAssertFalse(engine.startMicMeter(for: "slot", ended: {}))
        engine.apply([AudioBinding(slotId: "slot", connection: connection, controllerIndex: 0, route: nil, facts: facts())])
        XCTAssertFalse(engine.startMicMeter(for: "slot", ended: {}))
        engine.stopMicMeter(for: "slot")
        XCTAssertEqual(engine.state["slot"]?.micMeter, nil)
    }
}
