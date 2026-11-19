// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import CoreAudio
import DishCore
import XCTest
@testable import DishEngine

/// What the engine does with an endpoint the system refuses: the slot reads
/// refused, its caps follow so the satellite falls back to rumble, the same
/// endpoint is not asked again, and a pad that enumerates afresh is a new
/// attempt. Split from ControllerAudioEngineTests to keep each suite under
/// the type-length gate.
@MainActor
final class ControllerAudioEngineRefusalTests: XCTestCase {

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

    private func dualSense(id: AudioObjectID = 7, uid: String = "ds") -> PadAudioFunction {
        PadAudioFunction(
            device: AudioDeviceFacts(
                id: id,
                uid: uid,
                name: "DualSense Wireless Controller",
                isUSB: true,
                inputChannels: 1,
                outputChannels: 4
            ),
            family: .dualSense
        )
    }

    private func facts() -> AudioFacts {
        AudioFacts(
            routeMic: true,
            routeSpeaker: true,
            routeHapticLanes: true,
            micOn: true,
            speakerOn: true,
            host: HostAudioVerdict(mic: true, speaker: true, hapticAudio: true),
            live: true,
            micPermitted: true,
            muted: false
        )
    }

    private func binding(route: PadAudioFunction? = nil) -> AudioBinding {
        AudioBinding(slotId: "slot", connection: connection, controllerIndex: 0, route: route ?? dualSense(), facts: facts())
    }

    func testAnOutputTheSystemRefusesMarksTheSlotRefusedAndIsNotAskedAgainOnThatEndpoint() {
        ports.refuseOutput = true
        engine.apply([binding()])
        XCTAssertEqual(engine.state["slot"]?.playbackRefused, true)
        XCTAssertEqual(engine.state["slot"]?.plan.speakerVoice, false)
        XCTAssertEqual(engine.state["slot"]?.plan.capHapticAudio, false, "the caps follow, so the satellite falls back to rumble")
        XCTAssertEqual(engine.state["slot"]?.plan.capMic, true, "the microphone is its own endpoint")
        XCTAssertEqual(ports.outputRequests, 1)

        ports.refuseOutput = false
        engine.apply([binding()])
        XCTAssertEqual(ports.outputRequests, 1, "the same endpoint is not asked again")
        XCTAssertEqual(engine.state["slot"]?.playbackRefused, true)
    }

    func testARefusalIsSpentWhenThePadsEndpointChanges() {
        ports.refuseOutput = true
        engine.apply([binding()])
        ports.refuseOutput = false
        engine.apply([binding(route: dualSense(id: 8, uid: "ds-again"))])
        XCTAssertEqual(ports.outputRequests, 2, "a new device id is a new attempt")
        XCTAssertEqual(engine.state["slot"]?.playbackRefused, false)
        XCTAssertEqual(engine.state["slot"]?.plan.speakerVoice, true)
        XCTAssertEqual(ports.outputs.last?.started, true)
    }

    func testAnInputTheSystemRefusesMarksCaptureRefusedAndDisarmsTheMic() {
        ports.refuseInput = true
        engine.apply([binding()])
        XCTAssertEqual(engine.state["slot"]?.captureRefused, true)
        XCTAssertEqual(engine.state["slot"]?.plan.micArmed, false)
        XCTAssertEqual(engine.state["slot"]?.plan.capMic, false)
        XCTAssertEqual(engine.state["slot"]?.plan.capSpeaker, true, "the output is its own endpoint")
        XCTAssertEqual(ports.inputRequests, 1)

        engine.apply([binding()])
        XCTAssertEqual(ports.inputRequests, 1, "the same device is not asked again")
    }
}
