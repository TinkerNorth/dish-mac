// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import XCTest
@testable import DishCore
@testable import DishEngine

/// What the bindings ask of every host, and how a host reads as a row.
final class MoonlightDesireTests: XCTestCase {

    private let dualSense = ControllerCapabilities(
        hasMotion: true,
        hasTouchpad: true,
        hasRumble: true,
        hasLightbar: true,
        hasBattery: true,
        hasTriggerEffects: true,
        hasPlayerLeds: true
    )
    private let hostId = "moonlight:10.0.0.5"

    private func slot(_ id: String, _ capabilities: ControllerCapabilities) -> GameControllerInput.Slot {
        GameControllerInput.Slot(id: id, name: id, capabilities: capabilities, battery: nil, family: .dualSense)
    }

    func testTheRequestResolvesThePickAgainstThePadAndFoldsTheSwitchesTheHostReads() {
        let auto = MoonlightDesire.request(
            slotId: "ds",
            capabilities: dualSense,
            storedType: Int(MoonlightControllerType.auto),
            flags: ForwardingFlags()
        )
        XCTAssertEqual(auto.slotId, "ds")
        XCTAssertEqual(auto.announced.type, MoonlightControllerType.playStation, "Auto with motion is a PlayStation pad")
        XCTAssertEqual(auto.announced.capabilities, 0xFF)
        XCTAssertEqual(auto.announced.supportedButtons, 0x10F7FF)
        let motionOff = MoonlightDesire.request(
            slotId: "ds",
            capabilities: dualSense,
            storedType: Int(MoonlightControllerType.auto),
            flags: ForwardingFlags(motion: false)
        )
        XCTAssertEqual(motionOff.announced.type, MoonlightControllerType.xbox, "the motion switch folds in before Auto resolves")
        XCTAssertEqual(motionOff.announced.capabilities & (MoonlightCapability.gyro | MoonlightCapability.accelerometer), 0)
        let mouse = MoonlightDesire.request(
            slotId: "ds",
            capabilities: dualSense,
            storedType: Int(MoonlightControllerType.playStation),
            flags: ForwardingFlags(touchpadPick: .mouse)
        )
        XCTAssertEqual(mouse.announced.capabilities & MoonlightCapability.touchpad, 0, "no touchpad on a pad whose touches go elsewhere")
        XCTAssertEqual(mouse.announced.supportedButtons, 0xF7FF)
        let plain = MoonlightDesire.request(
            slotId: "xb",
            capabilities: ControllerCapabilities(hasRumble: true),
            storedType: 0,
            flags: ForwardingFlags()
        )
        XCTAssertEqual(plain.announced.type, MoonlightControllerType.xbox, "a stored 0 reads as Auto, and without motion Auto is Xbox")
        XCTAssertEqual(plain.announced.capabilities, MoonlightCapability.analogTriggers | MoonlightCapability.rumble)
    }

    func testTheDesireNamesOnlyMoonlightBindingsWhosePadIsPresent() {
        let desired = MoonlightDesire.desiredPads(
            bindings: ["ds": hostId, "xb": "mid:sat", "gone": hostId, "nin": "moonlight:10.0.0.9"],
            hostIds: [hostId],
            slots: [slot("ds", dualSense), slot("xb", ControllerCapabilities()), slot("nin", ControllerCapabilities())],
            overrides: [SlotKey(connectionId: hostId, slotId: "ds"): Int(MoonlightControllerType.nintendo)],
            hostTypes: { _ in Int(MoonlightControllerType.playStation) },
            preferences: ["ds": SlotPreferences(rumble: false)],
            global: ForwardingFlags()
        )
        XCTAssertEqual(desired.keys.sorted(), [hostId], "a satellite binding, an absent pad and an unknown host ask nothing")
        XCTAssertEqual(desired[hostId]?.map(\.slotId), ["ds"])
        XCTAssertEqual(
            desired[hostId]?.first?.announced.type,
            MoonlightControllerType.nintendo,
            "the pick per binding beats the host's own"
        )
        XCTAssertEqual(desired[hostId]?.first?.announced.capabilities, 0x47, "Nintendo sits on the Xbox ceiling; rumble is a hardware fact")
        let hostPick = MoonlightDesire.desiredPads(
            bindings: ["ds": hostId],
            hostIds: [hostId],
            slots: [slot("ds", dualSense)],
            overrides: [:],
            hostTypes: { _ in Int(MoonlightControllerType.playStation) },
            preferences: [:],
            global: ForwardingFlags()
        )
        XCTAssertEqual(hostPick[hostId]?.first?.announced.type, MoonlightControllerType.playStation)
    }

    func testTheRowsChipFollowsThePhaseThenTheTrust() {
        XCTAssertEqual(MoonlightDesire.linkState(phase: .streaming, paired: true, verified: false, discovered: false), .connected)
        XCTAssertEqual(MoonlightDesire.linkState(phase: .launching, paired: true, verified: false, discovered: false), .connecting)
        XCTAssertEqual(MoonlightDesire.linkState(phase: .rtsp(.play), paired: true, verified: false, discovered: false), .connecting)
        XCTAssertEqual(MoonlightDesire.linkState(phase: .failed(.dropped), paired: true, verified: true, discovered: true), .unstable)
        XCTAssertEqual(MoonlightDesire.linkState(phase: .failed(.trustLost), paired: true, verified: true, discovered: true), .stale)
        XCTAssertEqual(MoonlightDesire.linkState(phase: .failed(.hostReplaced), paired: true, verified: false, discovered: true), .stale)
        XCTAssertEqual(
            MoonlightDesire.linkState(phase: .idle, paired: false, verified: false, discovered: true),
            .stale,
            "no pairing: Needs pairing"
        )
        XCTAssertEqual(MoonlightDesire.linkState(phase: .idle, paired: true, verified: false, discovered: true), .ready)
        XCTAssertEqual(
            MoonlightDesire.linkState(phase: .idle, paired: true, verified: true, discovered: false),
            .ready,
            "proved this process"
        )
        XCTAssertEqual(MoonlightDesire.linkState(phase: .idle, paired: true, verified: false, discovered: false), .saved)
        XCTAssertEqual(MoonlightDesire.linkState(phase: .failed(.unreachable), paired: true, verified: false, discovered: false), .saved)
        XCTAssertEqual(MoonlightDesire.linkState(phase: .failed(.launchRejected), paired: true, verified: true, discovered: true), .ready)
    }

    func testTheSummaryCarriesTheHostsNameAddressAndEveryBoundSlot() {
        let summary = MoonlightDesire.summary(
            host: MoonlightHost(name: "", address: "10.0.0.5"),
            phase: .streaming,
            roundTripMs: 9,
            paired: true,
            verified: true,
            discovered: true,
            boundSlotIds: ["a", "b"]
        )
        XCTAssertEqual(summary.id, "moonlight:10.0.0.5")
        XCTAssertEqual(summary.name, "", "the engine vends the name as advertised, empty or not")
        XCTAssertEqual(summary.address, "10.0.0.5")
        XCTAssertNil(summary.udpPort, "a Moonlight host has no satellite port")
        XCTAssertEqual(summary.recordName, "10.0.0.5", "the log names a host with no name by its address")
        XCTAssertEqual(summary.live, .connected)
        XCTAssertEqual(summary.kind, .moonlight)
        XCTAssertEqual(summary.boundSlotId, "a")
        XCTAssertEqual(summary.boundSlotIds, ["a", "b"])
        XCTAssertEqual(summary.latencyMs, 4.5, "half the control link's round trip, as the satellite's figure is one way")
        XCTAssertTrue(summary.hasRoomForAnotherSlot)
        var full = summary
        full.boundSlotIds = ["a", "b", "c", "d"]
        XCTAssertFalse(full.hasRoomForAnotherSlot)
        let satellite = ConnectionSummary(id: "mid:1", name: "Desk", live: .ready, boundSlotId: "a")
        XCTAssertEqual(satellite.boundSlotIds, ["a"], "the one bound slot, as the list")
        XCTAssertTrue(satellite.hasRoomForAnotherSlot, "a satellite carries four pads")
    }
}
