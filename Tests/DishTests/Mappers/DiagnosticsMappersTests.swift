// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import DishEngine
import XCTest
@testable import Dish

/// The Diagnostics window's lines, from the facts the engine vends.
final class DiagnosticsMappersTests: XCTestCase {

    private let english = Locale(identifier: "en_US")

    private func summary(_ live: LinkState = .connected) -> ConnectionSummary {
        ConnectionSummary(id: "sat", name: "Desk", address: "10.0.0.2", udpPort: 9876, live: live, boundSlotId: nil)
    }

    private func liveFacts(
        hostEpoch: Int? = 4, hostBitmap: UInt16? = 0b1, backend: Bool? = true, active: Int? = 1,
        latency: LatencySummary = LatencySummary(p50RttMs: nil, p99RttMs: nil, samples: 0, capacity: 64)
    ) -> HostSessionFacts {
        HostSessionFacts(
            id: "sat",
            live: true,
            offeredProtocol: 3,
            settledProtocol: 3,
            compat: .current,
            appliedEpoch: 4,
            hostEpoch: hostEpoch,
            hostBitmap: hostBitmap,
            confirmedBitmap: 0b1,
            backendAvailable: backend,
            activeControllers: active,
            missedAcks: 0,
            mouseControlGranted: false,
            latency: latency
        )
    }

    // MARK: - Hosts

    func testARestingHostShowsItsAddressAndNoSession() {
        let lines = hostLines(HostDiagnostics(summary: summary(.saved), facts: .resting(id: "sat")), locale: english)
        XCTAssertEqual(
            lines,
            [FactLine(key: "Address", value: "10.0.0.2 • UDP 9876"), FactLine(key: "Session", value: "No session right now")]
        )
    }

    func testALiveHostTellsItsWholeStory() {
        let lines = hostLines(HostDiagnostics(summary: summary(), facts: liveFacts()), locale: english)
        XCTAssertEqual(
            lines.map(\.key),
            [
                "Address", "Protocol", "Epoch", "Controllers", "Virtual controllers", "Round trip", "Missed heartbeats", "Mouse control",
                "Controller audio"
            ]
        )
        XCTAssertEqual(lines[1].value, "v3")
        XCTAssertEqual(lines[2].value, "on the host: 4 · applied: 4 · in step")
        XCTAssertEqual(lines[3].value, "on the host: 0 · confirmed: 0 · in step")
        XCTAssertEqual(lines[4].value, "available · 1 in use")
        XCTAssertEqual(lines[5].value, "no samples yet")
        XCTAssertEqual(lines[6].value, "0")
        XCTAssertEqual(lines[7].value, "not granted")
        XCTAssertEqual(lines[8].value, "not granted")
    }

    func testTheHostsAudioLineNamesWhatItGranted() {
        XCTAssertEqual(hostAudioText(.none), "not granted")
        XCTAssertEqual(hostAudioText(HostAudioVerdict(mic: true, speaker: true, hapticAudio: true)), "Microphone · Speaker · Haptic audio")
        XCTAssertEqual(hostAudioText(HostAudioVerdict(mic: false, speaker: true, hapticAudio: false)), "Speaker")
    }

    func testBeforeTheFirstAckTheHostSaysSo() {
        let facts = liveFacts(hostEpoch: nil, hostBitmap: nil, backend: nil, active: nil)
        XCTAssertEqual(epochText(facts), "applied: 4 · waiting for the first heartbeat")
        XCTAssertEqual(controllersText(facts), "confirmed: 0 · waiting for the first heartbeat")
        XCTAssertEqual(backendText(facts), "unknown")
    }

    func testDriftReadsOutOfStep() {
        let facts = liveFacts(hostEpoch: 5, hostBitmap: 0b11)
        XCTAssertEqual(epochText(facts), "on the host: 5 · applied: 4 · out of step")
        XCTAssertEqual(controllersText(facts), "on the host: 0, 1 · confirmed: 0 · out of step")
        XCTAssertEqual(indexListText([]), "none")
    }

    func testTheProtocolLineNamesTheOfferAndTheStandingWhenTheyMatter() {
        let lowered = HostSessionFacts(
            id: "sat",
            live: true,
            offeredProtocol: 3,
            settledProtocol: 1,
            compat: .satelliteUpdateAvailable,
            appliedEpoch: 0,
            hostEpoch: nil,
            hostBitmap: nil,
            confirmedBitmap: 0,
            backendAvailable: nil,
            activeControllers: nil,
            missedAcks: 0,
            mouseControlGranted: true,
            latency: LatencySummary(p50RttMs: nil, p99RttMs: nil, samples: 0, capacity: 64)
        )
        XCTAssertTrue(protocolText(lowered).hasPrefix("v1 (offered v3) · "), protocolText(lowered))
        XCTAssertEqual(protocolText(liveFacts()), "v3")
        let mouse = hostLines(HostDiagnostics(summary: summary(), facts: lowered), locale: english).first { $0.key == "Mouse control" }
        XCTAssertEqual(mouse?.value, "granted")
    }

    func testTheRoundTripLineCarriesTheThreeFiguresAndTheFill() {
        let latency = LatencySummary(p50RttMs: 12.0, p99RttMs: 40.25, samples: 5, capacity: 64)
        XCTAssertEqual(roundTripText(latency, locale: english), "12.0 ms p50 · 40.2 ms p99 · 6.0 ms one way · 5 of 64 pings")
        XCTAssertEqual(
            roundTripText(latency, locale: Locale(identifier: "de_DE")),
            "12,0 ms p50 · 40,2 ms p99 · 6,0 ms one way · 5 of 64 pings"
        )
    }

    // MARK: - Controllers

    func testAnUnboundPadShowsItsFrameworkAndNoBinding() {
        let lines = padLines(PadDiagnostics(slot: ControllerSlot(id: "pad", name: "DualSense"), wire: nil, backgroundInput: true))
        XCTAssertEqual(lines, [
            FactLine(key: "Connection", value: "GameController"),
            FactLine(key: "Background input", value: "On"),
            FactLine(key: "Binding", value: "Not bound")
        ])
    }

    func testThePadSaysWhetherItsInputReachesDishInTheBackground() {
        let slot = ControllerSlot(id: "pad", name: "DualSense")
        let on = padLines(PadDiagnostics(slot: slot, wire: nil, backgroundInput: true))
        XCTAssertEqual(on.first { $0.key == "Background input" }?.value, "On")
        let off = padLines(PadDiagnostics(slot: slot, wire: nil, backgroundInput: false))
        XCTAssertEqual(off.first { $0.key == "Background input" }?.value, "Off")
    }

    func testABoundPadReadsItsTypeItsBatteryAndTheWire() {
        var slot = ControllerSlot(id: "pad", name: "DualSense")
        slot.boundConnectionId = "sat"
        slot.boundStatus = summary()
        slot.battery = BatteryReading(level: 80, state: .charging)
        slot.emulation = SlotEmulation(type: 2, isOverride: false, offered: [
            PickableType(id: 2, slug: "dualsense", name: "DualSense", shortName: "DualSense", description: "")
        ])
        let wire = SlotWireFacts(
            controllerIndex: 0,
            type: 2,
            caps: ProtocolConstants.capRumble | ProtocolConstants.capMotion,
            touchpad: .pad,
            confirmed: true,
            streaming: .yes
        )
        let lines = padLines(PadDiagnostics(slot: slot, wire: wire))
        XCTAssertEqual(lines.map(\.key), [
            "Connection", "Background input", "Type", "Battery", "Binding", "Controller index", "Confirmed by host",
            "Streaming", "Advertised", "Touchpad on the wire"
        ])
        XCTAssertEqual(lines[2].value, "DualSense")
        XCTAssertEqual(lines[3].value, batteryHelp(BatteryReading(level: 80, state: .charging)))
        XCTAssertEqual(lines[4].value, "Desk · Satellite")
        XCTAssertEqual(lines[5].value, "0")
        XCTAssertEqual(lines[6].value, "yes")
        XCTAssertEqual(lines[7].value, "yes")
        XCTAssertEqual(lines[8].value, "Rumble · Motion")
        XCTAssertEqual(lines[9].value, "pad")
    }

    private var dualSenseFunction: PadAudioFunction {
        let device = AudioDeviceFacts(
            id: 9,
            uid: "ds",
            name: "DualSense Wireless Controller",
            isUSB: true,
            inputChannels: 1,
            outputChannels: 4
        )
        return PadAudioFunction(device: device, family: .dualSense)
    }

    private func armedPlan(muted: Bool = false) -> AudioPlan {
        let host = HostAudioVerdict(mic: true, speaker: true, hapticAudio: true)
        let facts = AudioFacts(
            routeMic: true,
            routeSpeaker: true,
            routeHapticLanes: true,
            micOn: true,
            host: host,
            live: true,
            micPermitted: true,
            muted: muted
        )
        return audioPlan(facts)
    }

    func testAPadsAudioLinesFollowItsRouteAndItsPlan() {
        let slot = ControllerSlot(id: "pad", name: "DualSense", audioRoute: .routed)
        let routed = PadAudioRoute(verdict: .routed, function: dualSenseFunction)
        let unbound = PadDiagnostics(slot: slot, wire: nil, audio: PadAudioDiagnostics(route: routed, state: nil, counters: nil))
        XCTAssertEqual(audioLines(unbound), [FactLine(key: "Controller audio", value: "DualSense Wireless Controller")])
        XCTAssertEqual(audioLines(PadDiagnostics(slot: slot, wire: nil)), [], "no catalog read, no lines")

        let xbox = PadAudioRoute(verdict: .familyWithoutAudio, function: nil)
        let noAudio = PadDiagnostics(slot: slot, wire: nil, audio: PadAudioDiagnostics(route: xbox, state: nil, counters: nil))
        XCTAssertEqual(audioLines(noAudio), [], "a family without audio has no lines")

        let state = ControllerAudioState(plan: armedPlan(), micLed: .pulse)
        let counters = AudioCounters(speakerPlayed: 50, speakerConcealed: 2, hapticPlayed: 7, hapticConcealed: 0, micSent: 12)
        let bound = PadDiagnostics(slot: slot, wire: nil, audio: PadAudioDiagnostics(route: routed, state: state, counters: counters))
        let lines = audioLines(bound)
        XCTAssertEqual(lines.map(\.key), ["Controller audio", "Microphone", "Speaker", "Haptics", "Mic lamp"])
        XCTAssertEqual(lines[1].value, "capturing · 12 sent")
        XCTAssertEqual(lines[2].value, "playing · 50 played · 2 concealed")
        XCTAssertEqual(lines[3].value, "playing · 7 played · 0 concealed")
        XCTAssertEqual(lines[4].value, "Pulse")
        XCTAssertEqual(padLines(bound).suffix(5), lines, "the pad's card ends with its audio")
    }

    func testEveryAudioWordIsSpelled() {
        XCTAssertEqual(micStateText(armedPlan(muted: true), sent: 3), "armed, muted")
        XCTAssertEqual(micStateText(.silent, sent: 0), "off")
        XCTAssertEqual(laneText(false, played: 0, concealed: 0), "idle")
        XCTAssertEqual(micLampText(nil), "Off")
        XCTAssertEqual(micLampText(.off), "Off")
        XCTAssertEqual(micLampText(.on), "On")
        let unplugged = PadAudioRoute(verdict: .noAudioFunction, function: nil)
        XCTAssertEqual(audioRouteText(unplugged), "no USB audio function on this controller")
        let twoPads = PadAudioRoute(verdict: .padNameShared, function: nil)
        XCTAssertEqual(audioRouteText(twoPads), "two controllers share one name, so neither is routed")
        let twoDevices = PadAudioRoute(verdict: .endpointNameShared, function: nil)
        XCTAssertEqual(audioRouteText(twoDevices), "macOS lists more than one audio device under its name, so it is not routed")
    }

    func testABoundPadWithoutADescriptorIsNotDeclaredYet() {
        var slot = ControllerSlot(id: "pad", name: "Pad")
        slot.boundStatus = summary(.connecting)
        let lines = bindingLines(PadDiagnostics(slot: slot, wire: nil))
        XCTAssertEqual(
            lines,
            [FactLine(key: "Binding", value: "Desk · Satellite"), FactLine(key: "On the wire", value: "Not declared to the host yet")]
        )
    }

    func testEveryWireWordIsSpelled() {
        XCTAssertEqual(streamingText(.unknown), "waiting for the first heartbeat")
        XCTAssertEqual(streamingText(.no), "no")
        XCTAssertEqual(advertisedText(0), "nothing")
        XCTAssertEqual(
            advertisedText(0xFFFF),
            "Analog triggers · Rumble · Motion · Light bar · Adaptive triggers · Player LEDs · Microphone · Speaker · Haptic audio"
        )
        XCTAssertEqual(wireTouchpadText(.off), "off")
        XCTAssertEqual(wireTouchpadText(.mouse), "mouse")
    }

    // MARK: - Events

    func testEveryEventKindHasItsLine() {
        XCTAssertEqual(
            eventText(DiagnosticsEvent(atMs: 0, kind: .linkAppeared, subject: "Desk", to: .saved)),
            "Desk: appeared, \(linkStateText(.saved))"
        )
        XCTAssertEqual(
            eventText(DiagnosticsEvent(atMs: 0, kind: .linkChanged, subject: "Desk", from: .connecting, to: .connected)),
            "Desk: \(linkStateText(.connecting)) → \(linkStateText(.connected))"
        )
        XCTAssertEqual(eventText(DiagnosticsEvent(atMs: 0, kind: .linkRemoved, subject: "Desk")), "Desk: removed")
        XCTAssertEqual(eventText(DiagnosticsEvent(atMs: 0, kind: .padAttached, subject: "Pad")), "Pad: attached")
        XCTAssertEqual(eventText(DiagnosticsEvent(atMs: 0, kind: .padDetached, subject: "Pad")), "Pad: detached")
        XCTAssertEqual(eventText(DiagnosticsEvent(atMs: 0, kind: .padBound, subject: "Pad", host: "Desk")), "Pad: bound to Desk")
        XCTAssertEqual(eventText(DiagnosticsEvent(atMs: 0, kind: .padUnbound, subject: "Pad", host: "Desk")), "Pad: unbound from Desk")
    }

    func testALineLeadsWithTheLocalTimeAndTheTranscriptKeepsTheOrder() throws {
        let utc = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let british = Locale(identifier: "en_GB")
        let first = DiagnosticsEvent(sequence: 1, atMs: 3_600_000, kind: .linkRemoved, subject: "Desk")
        let second = DiagnosticsEvent(sequence: 2, atMs: 3_661_000, kind: .padDetached, subject: "Pad")
        XCTAssertEqual(eventTimeText(first.atMs, locale: british, timeZone: utc), "01:00:00")
        XCTAssertEqual(eventLine(first, locale: british, timeZone: utc), "01:00:00  Desk: removed")
        XCTAssertEqual(
            eventsTranscript([first, second], locale: british, timeZone: utc),
            "01:00:00  Desk: removed\n01:01:01  Pad: detached"
        )
    }

    func testTheWindowShowsTheNewestThirtyNewestFirst() {
        let events = (1 ... 40).map { DiagnosticsEvent(sequence: $0, atMs: Int64($0), kind: .linkRemoved, subject: "x") }
        let shown = recentEvents(events)
        XCTAssertEqual(shown.count, 30)
        XCTAssertEqual(shown.first?.sequence, 40)
        XCTAssertEqual(shown.last?.sequence, 11)
    }
}
