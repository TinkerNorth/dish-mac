// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import DishEngine
import XCTest
@testable import Dish

/// The words and colours of the capability table, the Emulate picker, the
/// gyro chip's satellite word and the link tier, from a slot's facts.
final class CapabilityMappersTests: XCTestCase {

    private let offered = [
        PickableType(id: 0, slug: "xbox360", name: "Xbox 360 Controller", shortName: "Xbox", description: ""),
        PickableType(id: 2, slug: "dualsense", name: "DualSense", shortName: "DualSense", description: "")
    ]

    private let dualSenseFeatures = TypeFeatureFacts(
        motion: true, touchpad: true, rumble: true, lightbar: true, triggerEffects: true, playerLeds: true, mic: true, speaker: true
    )

    private let xboxFeatures = TypeFeatureFacts(
        motion: false, touchpad: false, rumble: true, lightbar: false, triggerEffects: false, playerLeds: false, mic: false, speaker: false
    )

    private static let everyCapability = ControllerCapabilities(
        hasMotion: true,
        hasTouchpad: true,
        hasRumble: true,
        hasLightbar: true,
        hasBattery: true,
        hasTriggerEffects: true,
        hasPlayerLeds: true
    )

    private func bound(_ live: LinkState = .connected) -> ConnectionSummary {
        ConnectionSummary(id: "sat", label: "Desk", detail: "", live: live, boundSlotId: "pad")
    }

    /// A DualSense bound to a probed satellite that offers its type.
    private func dualSense(
        type: Int = 2,
        override: Bool = false,
        features: TypeFeatureFacts? = nil,
        probe: HostProbeFacts? = nil
    ) -> ControllerSlot {
        ControllerSlot(
            id: "pad",
            name: "DualSense",
            boundConnectionId: "sat",
            boundStatus: bound(),
            capabilities: Self.everyCapability,
            emulation: SlotEmulation(type: type, isOverride: override, offered: offered),
            typeFeatures: features ?? dualSenseFeatures,
            hostProbe: probe ?? HostProbeFacts(mouseControl: true, rumble: true, mic: false, speaker: false)
        )
    }

    private func row(_ feature: CapFeature, in table: [CapabilityRowModel]) throws -> CapabilityRowModel {
        try XCTUnwrap(table.first { $0.feature == feature })
    }

    // MARK: - The inputs

    func testTheInputsReadThePadTheTypeTheHostAndTheSwitches() {
        let inputs = capabilityInputs(dualSense(), ForwardingFlags(motion: false, touchpad: true, rumble: true, lightbar: false))
        XCTAssertTrue(inputs.padMotion && inputs.padTouchpad && inputs.padRumble && inputs.padLightbar)
        XCTAssertTrue(inputs.padTriggerEffects && inputs.padPlayerLeds)
        XCTAssertFalse(inputs.padMic || inputs.padSpeaker, "no audio route read for this pad")
        XCTAssertFalse(inputs.linkRoutesMouse, "this client routes no mouse")
        XCTAssertTrue(inputs.typeResolved && inputs.typeMotion && inputs.typeMic)
        XCTAssertTrue(inputs.hostResolved && inputs.hostRumble && inputs.hostMouseControl)
        XCTAssertFalse(inputs.hostMic)
        XCTAssertFalse(inputs.userMotionOn)
        XCTAssertTrue(inputs.userRumbleOn)
        XCTAssertFalse(inputs.userLightbarOn)
        XCTAssertEqual(inputs.userTouchpadPick, .pad)
    }

    func testTheTouchpadSwitchOffIsNoPick() {
        XCTAssertEqual(capabilityInputs(dualSense(), ForwardingFlags(touchpad: false)).userTouchpadPick, .off)
    }

    func testMissingFactsLeaveTheLayersUnresolved() {
        var slot = dualSense()
        slot.typeFeatures = nil
        slot.hostProbe = nil
        let inputs = capabilityInputs(slot, ForwardingFlags())
        XCTAssertFalse(inputs.typeResolved)
        XCTAssertFalse(inputs.hostResolved)
    }

    private func help(_ feature: CapFeature, _ slot: ControllerSlot, _ flags: ForwardingFlags = ForwardingFlags()) throws -> String {
        try row(feature, in: capabilityTable(slot, flags)).help
    }

    func testTheAudioLayersReadTheFamilyAndTheRoute() {
        var routed = dualSense()
        routed.capabilities = ControllerCapabilities(hasMic: true, hasSpeaker: true, hasHapticLanes: true)
        routed.audioRoute = .routed
        let inputs = capabilityInputs(routed, ForwardingFlags())
        XCTAssertTrue(inputs.padMic && inputs.padSpeaker && inputs.linkRoutesMic && inputs.linkRoutesSpeaker)

        var bluetooth = dualSense()
        bluetooth.audioRoute = .noAudioFunction
        let unrouted = capabilityInputs(bluetooth, ForwardingFlags())
        XCTAssertTrue(unrouted.padMic, "the pad has a mic whether or not this Mac reaches it")
        XCTAssertFalse(unrouted.linkRoutesMic)

        var xbox = dualSense()
        xbox.audioRoute = .familyWithoutAudio
        XCTAssertFalse(capabilityInputs(xbox, ForwardingFlags()).padMic)
    }

    func testTheLinkRowNamesWhyThePadsAudioIsNotRouted() throws {
        var slot = dualSense(probe: HostProbeFacts(mouseControl: true, rumble: true, mic: true, speaker: true))
        slot.audioRoute = .noAudioFunction
        XCTAssertEqual(try help(.mic, slot), "The pad’s audio needs USB; over Bluetooth it has no channel.")
        slot.audioRoute = .padNameShared
        XCTAssertEqual(try help(.speaker, slot), "Two controllers share one name, so neither gets its audio.")
        slot.audioRoute = .endpointNameShared
        let shared = "macOS lists more than one audio device under this pad’s name, so its audio is not routed."
        XCTAssertEqual(try help(.mic, slot), shared)
        slot.audioRoute = .familyWithoutAudio
        XCTAssertEqual(try help(.mic, slot), "The pad has no Microphone.", "an Xbox pad fails at the pad")
        slot.audioRoute = .routed
        slot.capabilities = ControllerCapabilities(hasMic: true, hasSpeaker: true)
        let table = capabilityTable(slot, ForwardingFlags(mic: true))
        XCTAssertEqual(try row(.mic, in: table).verdictText, "Supported")
        XCTAssertEqual(try row(.speaker, in: table).verdictText, "Supported")
        XCTAssertEqual(try row(.mic, in: capabilityTable(slot, ForwardingFlags())).verdictText, "Off", "the mic is off until asked")
    }

    // MARK: - The table

    func testTheTableWordsEveryVerdictAndNamesTheFailingLayer() throws {
        let table = capabilityTable(dualSense(), ForwardingFlags(lightbar: false))
        XCTAssertEqual(table.map(\.label), [
            "Gamepad", "Analog triggers", "Motion", "Touchpad", "Mouse", "Rumble", "Light bar",
            "Adaptive triggers", "Player LEDs", "Microphone", "Speaker"
        ])
        let gamepad = try row(.gamepad, in: table)
        XCTAssertEqual(gamepad.verdictText, "Supported")
        XCTAssertEqual(gamepad.help, "Every layer carries it: the pad, this Mac, the DualSense type and the host.")
        let mouse = try row(.mouse, in: table)
        XCTAssertEqual(mouse.verdictText, "Not available")
        XCTAssertEqual(mouse.help, "Dish on a Mac doesn’t route Mouse.")
        let mic = try row(.mic, in: table)
        XCTAssertEqual(mic.help, "The pad has no Microphone.", "the pad layer fails before the host's")
        let lightbar = try row(.lightbar, in: table)
        XCTAssertEqual(lightbar.verdictText, "Off")
        XCTAssertEqual(lightbar.help, "Switched off in Settings.")
    }

    func testTheTypeAndTheHostLayersBlameThemselves() throws {
        let xbox = capabilityTable(dualSense(type: 0, features: xboxFeatures), ForwardingFlags())
        XCTAssertEqual(try row(.motion, in: xbox).help, "Xbox doesn’t carry Motion.")
        let noRumble = capabilityTable(
            dualSense(probe: HostProbeFacts(mouseControl: false, rumble: false, mic: false, speaker: false)), ForwardingFlags()
        )
        XCTAssertEqual(try row(.rumble, in: noRumble).verdictText, "Not available")
        XCTAssertEqual(try row(.rumble, in: noRumble).help, "The host doesn’t carry Rumble.")
    }

    func testAnUnprobedHostReadsPendingThroughout() throws {
        var slot = dualSense()
        slot.hostProbe = nil
        let table = capabilityTable(slot, ForwardingFlags())
        XCTAssertEqual(Set(table.map(\.verdictText)), ["Pending"])
        XCTAssertEqual(try row(.motion, in: table).help, "Waiting for the host’s catalog and capabilities.")
    }

    func testEveryVerdictHasItsColour() {
        XCTAssertEqual(capabilityVerdictColor(.available), DishTheme.success)
        XCTAssertEqual(capabilityVerdictColor(.unavailable), DishTheme.error)
        XCTAssertEqual(capabilityVerdictColor(.pending), DishTheme.warning)
        XCTAssertEqual(capabilityVerdictColor(.off), DishTheme.muted)
    }

    // MARK: - The Emulate picker

    func testThePickerOffersAutoThenTheCatalogsTypes() {
        let emulation = SlotEmulation(type: 2, isOverride: false, offered: offered)
        XCTAssertEqual(emulateOptions(emulation), [
            EmulateOption(id: nil, label: "Auto"), EmulateOption(id: 0, label: "Xbox"), EmulateOption(id: 2, label: "DualSense")
        ])
        XCTAssertNil(emulateSelection(emulation), "no pick reads Auto")
        XCTAssertEqual(emulateSelection(SlotEmulation(type: 0, isOverride: true, offered: offered)), 0)
    }

    func testTheDetailSaysWhatAutoSendsAndFallsSilentForAPick() {
        XCTAssertEqual(
            emulateDetail(SlotEmulation(type: 2, isOverride: false, offered: offered)),
            "Auto sends DualSense for this controller."
        )
        XCTAssertEqual(emulateDetail(SlotEmulation(type: 0, isOverride: true, offered: offered)), "")
        XCTAssertEqual(emulateDetail(SlotEmulation(type: 0, isOverride: false, offered: [])), "Waiting on the type…")
    }

    func testAnUnnamedTypeReadsByItsNumber() {
        XCTAssertEqual(emulatedTypeName(SlotEmulation(type: 9, isOverride: true, offered: offered)), "Type 9")
        XCTAssertEqual(emulatedTypeName(nil), "Waiting on the type…")
    }

    // MARK: - The gyro chip

    func testTheMotionIndicatorFollowsTheBindingAndTheSatellitesWord() {
        var slot = dualSense()
        XCTAssertEqual(motionIndicator(slot, ForwardingFlags()), .forwarding, "no word yet reads as fine")
        slot.motionStatus = MotionBackendStatus(sinkSupportedForType: false, backendOk: true)
        XCTAssertEqual(motionIndicator(slot, ForwardingFlags()), .noHostSink)
        slot.motionStatus = MotionBackendStatus(sinkSupportedForType: true, backendOk: false)
        XCTAssertEqual(motionIndicator(slot, ForwardingFlags()), .backendBroken)
        slot.boundStatus = bound(.connecting)
        XCTAssertEqual(motionIndicator(slot, ForwardingFlags()), .notForwarded)
        XCTAssertEqual(motionIndicator(slot, ForwardingFlags(motion: false)), .userDisabled)
        slot.capabilities = .none
        XCTAssertEqual(motionIndicator(slot, ForwardingFlags()), .unavailable)
    }

    func testEveryMotionStateHasItsLineAndOnlyTheSatellitesFaultsWarn() {
        XCTAssertEqual(motionIndicatorText(.unavailable), "Motion: no gyroscope")
        XCTAssertEqual(motionIndicatorText(.userDisabled), "Motion: turned off")
        XCTAssertEqual(motionIndicatorText(.notForwarded), "Motion: not sent")
        XCTAssertEqual(motionIndicatorText(.noHostSink), "Motion: host can’t receive")
        XCTAssertEqual(motionIndicatorText(.backendBroken), "Motion: server can’t deliver")
        XCTAssertEqual(motionIndicatorText(.forwarding), "Motion: streaming")
        XCTAssertTrue(motionIndicatorWarns(.noHostSink))
        XCTAssertTrue(motionIndicatorWarns(.backendBroken))
        XCTAssertFalse(motionIndicatorWarns(.forwarding))
        XCTAssertFalse(motionIndicatorWarns(.userDisabled))
    }

    func testTheBoundGyroChipCarriesTheSatellitesWord() throws {
        var slot = dualSense()
        slot.motionStatus = MotionBackendStatus(sinkSupportedForType: false, backendOk: true)
        let chip = try XCTUnwrap(capabilityChips(for: slot, ForwardingFlags()).first)
        XCTAssertEqual(chip.label, "Gyro")
        XCTAssertFalse(chip.on)
        XCTAssertTrue(chip.warning)
        XCTAssertEqual(chip.help, "Motion: host can’t receive Click to turn it off for this controller.")
        slot.motionStatus = nil
        let streaming = try XCTUnwrap(capabilityChips(for: slot, ForwardingFlags()).first)
        XCTAssertTrue(streaming.on)
        XCTAssertFalse(streaming.warning)
        XCTAssertEqual(streaming.help, "Motion: streaming Click to turn it off for this controller.")
    }

    func testAnUnboundSlotKeepsTheDetectedChip() throws {
        var slot = dualSense()
        slot.boundConnectionId = nil
        slot.boundStatus = nil
        let chip = try XCTUnwrap(capabilityChips(for: slot, ForwardingFlags()).first)
        XCTAssertEqual(chip.help, "Motion detected — forwarding to the host is on Click to turn it off for this controller.")
        XCTAssertFalse(chip.warning)
    }

    // MARK: - The link tier

    func testEveryTierHasItsWordHelpAndColour() {
        XCTAssertEqual(linkTierText(.satellite), "Fastest")
        XCTAssertEqual(linkTierText(.moonlight), "Fast")
        XCTAssertEqual(linkTierText(.bluetooth), "Basic")
        XCTAssertEqual(linkTierHelp(.satellite), "A Satellite link: our own wire, one hop, every feature.")
        XCTAssertEqual(linkTierHelp(.moonlight), "A Moonlight host’s control stream.")
        XCTAssertEqual(linkTierHelp(.bluetooth), "The system’s Bluetooth gamepad layer.")
        XCTAssertEqual(linkTierColor(.satellite), DishTheme.success)
        XCTAssertEqual(linkTierColor(.moonlight), DishTheme.muted)
        XCTAssertEqual(linkTierColor(.bluetooth), DishTheme.warning)
    }
}
