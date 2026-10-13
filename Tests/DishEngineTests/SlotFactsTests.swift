// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import XCTest
@testable import DishEngine

/// The pure derivations behind the Emulate picker and the capability table:
/// which types are offered, which one a binding resolves to, and what the
/// type and the host carry.
final class SlotFactsTests: XCTestCase {

    private func catalog() throws -> CatalogDTO {
        try JSONDecoder().decode(CatalogDTO.self, from: Data(FakeSatelliteRest.catalogJSON.utf8))
    }

    private func probe(_ json: String) throws -> ServerCapabilitiesDTO {
        var probe = try JSONDecoder().decode(ServerCapabilitiesDTO.self, from: Data(json.utf8))
        probe.reachable = true
        return probe
    }

    // MARK: - The offered types

    func testEveryNamedTypeIsOfferedInCatalogOrder() throws {
        let offered = try offerableTypes(in: catalog())
        XCTAssertEqual(offered.map(\.id), [0, 1, 2, 3])
        XCTAssertEqual(offered.map(\.label), ["Xbox", "PlayStation", "DualSense", "Switch Pro"])
        XCTAssertEqual(offered[1].name, "DualShock 4")
        XCTAssertEqual(offered[1].description, "Motion, touchpad and light bar.")
    }

    func testANamelessTypeIsDroppedAndAShortNameAloneIsEnough() {
        var nameless = CatalogControllerType()
        nameless.id = 7
        XCTAssertFalse(isTypeOfferable(nameless))
        var shortOnly = CatalogControllerType()
        shortOnly.shortName = "Pad"
        XCTAssertTrue(isTypeOfferable(shortOnly))
        XCTAssertEqual(PickableType(id: 7, slug: "", name: "Long", shortName: "", description: "").label, "Long")
    }

    func testNoCatalogOffersNothing() {
        XCTAssertEqual(offerableTypes(in: nil), [])
    }

    // MARK: - The ladder

    func testTheUsersPickWinsOverTheFamily() throws {
        XCTAssertEqual(try emulatedControllerType(override: 3, catalog: catalog(), family: .dualSense), 3)
    }

    func testWithoutAPickTheFamilyPicksItsOwnType() throws {
        XCTAssertEqual(try emulatedControllerType(override: nil, catalog: catalog(), family: .dualSense), 2)
        XCTAssertEqual(try emulatedControllerType(override: nil, catalog: catalog(), family: .dualShock4), 1)
        XCTAssertEqual(try emulatedControllerType(override: nil, catalog: catalog(), family: .xbox), 0)
        XCTAssertEqual(try emulatedControllerType(override: nil, catalog: catalog(), family: .other), 0, "the first offered")
    }

    func testAPickSurvivesAMissingCatalog() {
        XCTAssertEqual(emulatedControllerType(override: 1, catalog: nil, family: .other), 1)
        XCTAssertEqual(emulatedControllerType(override: nil, catalog: nil, family: .dualSense), 0, "the legacy target")
    }

    // MARK: - What the type carries

    func testTheTypeFactsReadTheCatalogsFeatureFlags() throws {
        let dualSense = try XCTUnwrap(try typeFeatureFacts(in: catalog(), type: 2))
        XCTAssertEqual(
            dualSense,
            TypeFeatureFacts(
                motion: true,
                touchpad: true,
                rumble: true,
                lightbar: true,
                triggerEffects: true,
                playerLeds: true,
                mic: true,
                speaker: true
            )
        )
        let xbox = try XCTUnwrap(try typeFeatureFacts(in: catalog(), type: 0))
        XCTAssertEqual(
            xbox,
            TypeFeatureFacts(
                motion: false,
                touchpad: false,
                rumble: true,
                lightbar: false,
                triggerEffects: false,
                playerLeds: false,
                mic: false,
                speaker: false
            )
        )
    }

    func testAnUnknownTypeOrNoCatalogLeavesTheTypeUnresolved() throws {
        XCTAssertNil(try typeFeatureFacts(in: catalog(), type: 9))
        XCTAssertNil(typeFeatureFacts(in: nil, type: 0))
    }

    // MARK: - What the host carries

    func testTheHostFactsNeedSupportedAndAvailableAndReadTheAudioSwitches() throws {
        let facts = try XCTUnwrap(try hostProbeFacts(probe("""
        {"protocolVersion":3,"host":{"catalog":{"supported":true,"available":true},
         "mouseControl":{"supported":true,"available":false},"rumble":{"supported":true,"available":true}},
         "controllerAudio":{"enabled":true,"mic":true,"speaker":false,"hapticAudio":false}}
        """)))
        XCTAssertEqual(facts, HostProbeFacts(mouseControl: false, rumble: true, mic: true, speaker: false))
    }

    func testAnUnprobedOrUnreachableHostLeavesTheHostUnresolved() throws {
        XCTAssertNil(hostProbeFacts(nil))
        var unreachable = try probe("{}")
        unreachable.reachable = false
        XCTAssertNil(hostProbeFacts(unreachable))
    }

    // MARK: - The composed slot

    @MainActor
    func testABoundSlotCarriesItsEmulationAndFacts() throws {
        let gc = GameControllerInput.Slot(
            id: "pad",
            name: "DualSense",
            capabilities: ControllerCapabilities(hasMotion: true),
            family: .dualSense
        )
        let key = SlotKey(connectionId: "sat", slotId: "pad")
        let facts = try SlotFactsSnapshot(
            catalogs: ["sat": catalog()],
            probes: ["sat": probe("{\"host\":{\"rumble\":{\"supported\":true,\"available\":true}}}")],
            overrides: [key: 1],
            motion: [key: MotionBackendStatus(sinkSupportedForType: true, backendOk: false)]
        )
        let summary = ConnectionSummary(id: "sat", label: "Desk", detail: "", live: .connected, boundSlotId: "pad")
        let slots = composeSlots(gcSlots: [gc], connections: [summary], bindings: ["pad": "sat"], facts: facts)
        let slot = try XCTUnwrap(slots.first)
        XCTAssertEqual(slot.emulation, try SlotEmulation(type: 1, isOverride: true, offered: offerableTypes(in: catalog())))
        XCTAssertEqual(slot.emulation?.current?.label, "PlayStation")
        XCTAssertEqual(slot.typeFeatures?.lightbar, true)
        XCTAssertEqual(slot.hostProbe?.rumble, true)
        XCTAssertEqual(slot.motionStatus, MotionBackendStatus(sinkSupportedForType: true, backendOk: false))
        XCTAssertFalse(slot.motionStatus?.effective ?? true)
    }

    @MainActor
    func testAnUnboundSlotCarriesNoBindingFacts() throws {
        let gc = GameControllerInput.Slot(id: "pad", name: "Pad", capabilities: .none, family: .other)
        let slot = try XCTUnwrap(composeSlots(gcSlots: [gc], connections: [], bindings: [:]).first)
        XCTAssertNil(slot.emulation)
        XCTAssertNil(slot.typeFeatures)
        XCTAssertNil(slot.hostProbe)
        XCTAssertNil(slot.motionStatus)
        XCTAssertNil(slot.audio)
        XCTAssertNil(slot.audioRoute, "no audio catalog read yet")
    }

    /// The pad's route folds into its capabilities bound or not, the mute
    /// rides every slot, and the engine's word only a bound one.
    @MainActor
    func testTheAudioRouteFoldsIntoTheCapabilitiesAndTheEnginesWordRidesTheBinding() throws {
        let gc = GameControllerInput.Slot(
            id: "pad",
            name: "DualSense",
            capabilities: ControllerCapabilities(hasMotion: true),
            family: .dualSense
        )
        let device = AudioDeviceFacts(
            id: 9,
            uid: "ds",
            name: "DualSense Wireless Controller",
            isUSB: true,
            inputChannels: 1,
            outputChannels: 4
        )
        let function = PadAudioFunction(device: device, family: .dualSense)
        let state = ControllerAudioState(
            plan: audioPlan(AudioFacts(routeMic: true, routeSpeaker: true, routeHapticLanes: true)),
            micLed: .on
        )
        let facts = SlotFactsSnapshot(
            routes: ["pad": PadAudioRoute(verdict: .routed, function: function)],
            audio: ["pad": state],
            mutes: ["pad"]
        )
        let unbound = try XCTUnwrap(composeSlots(gcSlots: [gc], connections: [], bindings: [:], facts: facts).first)
        XCTAssertEqual(unbound.capabilities, ControllerCapabilities(hasMotion: true, hasMic: true, hasSpeaker: true, hasHapticLanes: true))
        XCTAssertEqual(unbound.audioRoute, .routed)
        XCTAssertTrue(unbound.micMuted)
        XCTAssertNil(unbound.audio, "the engine only speaks for a bound controller")

        let summary = ConnectionSummary(id: "sat", label: "Desk", detail: "", live: .connected, boundSlotId: "pad")
        let bound = try XCTUnwrap(composeSlots(gcSlots: [gc], connections: [summary], bindings: ["pad": "sat"], facts: facts).first)
        XCTAssertEqual(bound.audio, state)

        let shared = SlotFactsSnapshot(routes: ["pad": PadAudioRoute(verdict: .padNameShared, function: nil)])
        let unrouted = try XCTUnwrap(composeSlots(gcSlots: [gc], connections: [], bindings: [:], facts: shared).first)
        XCTAssertEqual(unrouted.capabilities, ControllerCapabilities(hasMotion: true), "an unrouted pad claims no audio")
        XCTAssertEqual(unrouted.audioRoute, .padNameShared)
    }

    @MainActor
    func testABindingWithoutACatalogResolvesTheLegacyTypeAndStaysUnresolved() throws {
        let gc = GameControllerInput.Slot(id: "pad", name: "Pad", capabilities: .none, family: .dualSense)
        let summary = ConnectionSummary(id: "sat", label: "Desk", detail: "", live: .connecting, boundSlotId: "pad")
        let slot = try XCTUnwrap(composeSlots(gcSlots: [gc], connections: [summary], bindings: ["pad": "sat"]).first)
        XCTAssertEqual(slot.emulation, SlotEmulation(type: 0, isOverride: false, offered: []))
        XCTAssertNil(slot.emulation?.current)
        XCTAssertNil(slot.typeFeatures)
        XCTAssertNil(slot.hostProbe)
    }
}
