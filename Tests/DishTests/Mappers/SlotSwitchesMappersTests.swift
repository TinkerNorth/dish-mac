// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import DishEngine
import XCTest
@testable import Dish

/// The chips double as the controller's own switches: clickable while the
/// global switch is on, worded for whichever switch is off.
final class SlotSwitchesMappersTests: XCTestCase {

    private func slot(_ preferences: SlotPreferences = SlotPreferences()) -> ControllerSlot {
        ControllerSlot(
            id: "pad",
            name: "DualSense",
            capabilities: ControllerCapabilities(hasMotion: true, hasTouchpad: true, hasRumble: true, hasLightbar: true),
            preferences: preferences
        )
    }

    private func chip(_ label: String, in chips: [CapabilityChipModel]) throws -> CapabilityChipModel {
        try XCTUnwrap(chips.first { $0.label == label })
    }

    func testEachSwitchedFeatureIsAClickableChipAndTheLightBarIsNot() throws {
        let chips = capabilityChips(for: slot(), ForwardingFlags())
        XCTAssertEqual(chips.map(\.label), ["Gyro", "Touchpad", "Rumble", "Lightbar"])
        XCTAssertEqual(try chip("Gyro", in: chips).switch, .motion)
        XCTAssertEqual(try chip("Touchpad", in: chips).switch, .touchpad)
        XCTAssertEqual(try chip("Rumble", in: chips).switch, .rumble)
        XCTAssertNil(try chip("Lightbar", in: chips).switch, "the light bar stays a global switch")
        XCTAssertFalse(try chip("Lightbar", in: chips).toggle)
        for label in ["Gyro", "Touchpad", "Rumble"] {
            XCTAssertTrue(try chip(label, in: chips).toggle, label)
            XCTAssertTrue(try chip(label, in: chips).on, label)
        }
    }

    func testTheControllersOwnSwitchOffReadsSoAndOffersTheClick() throws {
        let chips = capabilityChips(for: slot(SlotPreferences(rumble: false)), ForwardingFlags())
        let rumble = try chip("Rumble", in: chips)
        XCTAssertFalse(rumble.on)
        XCTAssertTrue(rumble.toggle)
        XCTAssertEqual(rumble.help, "Turned off for this controller. Click to turn it on for this controller.")
        XCTAssertEqual(
            try chip("Touchpad", in: chips).help,
            "Touchpad detected — forwarding to the host is on Click to turn it off for this controller."
        )
    }

    func testTheGlobalSwitchOffOutranksTheControllersAndIsNotClickable() throws {
        let chips = capabilityChips(for: slot(SlotPreferences(touchpad: .pad)), ForwardingFlags(touchpad: false))
        let touchpad = try chip("Touchpad", in: chips)
        XCTAssertFalse(touchpad.on)
        XCTAssertFalse(touchpad.toggle, "a click could not bring it back; Settings can")
        XCTAssertEqual(touchpad.help, "Touchpad detected — turned off in Settings")
    }

    func testTheTableFoldsTheControllersOwnSwitches() throws {
        var bound = slot(SlotPreferences(motion: false))
        bound.boundConnectionId = "sat"
        bound.boundStatus = ConnectionSummary(id: "sat", label: "Desk", detail: "", live: .connected, boundSlotId: "pad")
        bound.typeFeatures = TypeFeatureFacts(
            motion: true,
            touchpad: true,
            rumble: true,
            lightbar: true,
            triggerEffects: true,
            playerLeds: true,
            mic: true,
            speaker: true
        )
        bound.hostProbe = HostProbeFacts(mouseControl: true, rumble: true, mic: false, speaker: false)
        let effective = effectiveFlags(global: ForwardingFlags(), slot: bound.preferences)
        let motion = try XCTUnwrap(capabilityTable(bound, effective).first { $0.feature == .motion })
        XCTAssertEqual(motion.verdictText, "Off")
        XCTAssertEqual(motionIndicator(bound, effective), .userDisabled)
    }

    // MARK: - The pad's own audio

    private func audioSlot(_ preferences: SlotPreferences = SlotPreferences()) -> ControllerSlot {
        ControllerSlot(
            id: "pad",
            name: "DualSense",
            capabilities: ControllerCapabilities(hasMotion: true, hasMic: true, hasSpeaker: true),
            preferences: preferences,
            audioRoute: .routed
        )
    }

    private func armedPlan(muted: Bool = false) -> AudioPlan {
        let host = HostAudioVerdict(mic: true, speaker: true, hapticAudio: true)
        return audioPlan(AudioFacts(
            routeMic: true,
            routeSpeaker: true,
            micOn: true,
            host: host,
            live: true,
            micPermitted: true,
            muted: muted
        ))
    }

    func testThePadsOwnAudioChipsAnswerToTheControllerAlone() throws {
        let chips = capabilityChips(for: audioSlot(), ForwardingFlags())
        XCTAssertEqual(chips.map(\.label), ["Gyro", "Mic", "Speaker"])
        let mic = try chip("Mic", in: chips)
        XCTAssertFalse(mic.on, "the mic is off until asked")
        XCTAssertTrue(mic.toggle, "no global switch outranks it")
        XCTAssertEqual(mic.switch, .mic)
        XCTAssertEqual(mic.help, "Turned off for this controller. Click to turn it on for this controller.")
        let speaker = try chip("Speaker", in: chips)
        XCTAssertTrue(speaker.on)
        XCTAssertEqual(speaker.switch, .speaker)
        XCTAssertEqual(speaker.help, "Audio from the host plays on the pad’s speaker or headset. Click to turn it off for this controller.")
        let micOn = try chip("Mic", in: capabilityChips(for: audioSlot(SlotPreferences(mic: true)), ForwardingFlags()))
        XCTAssertEqual(
            micOn.help,
            "The pad’s mic carries your voice to the host. Off sends nothing. Click to turn it off for this controller."
        )
        XCTAssertFalse(micOn.warning)
    }

    func testAMicWithoutTheSystemsLeaveWarns() throws {
        let chips = capabilityChips(for: audioSlot(SlotPreferences(mic: true)), ForwardingFlags(), micPermitted: false)
        let mic = try chip("Mic", in: chips)
        XCTAssertTrue(mic.warning)
        XCTAssertTrue(mic.on)
        XCTAssertTrue(mic.toggle, "the switch can still be turned off")
        XCTAssertEqual(mic.help, "Microphone permission is off for Dish. Turn it on in system settings to use the controller microphone.")
        let off = try chip("Mic", in: capabilityChips(for: audioSlot(), ForwardingFlags(), micPermitted: false))
        XCTAssertFalse(off.warning, "a mic that is off needs no leave")
    }

    func testTheMicStatusChipAppearsOnceArmedAndTheLampWhenTheGameAsks() throws {
        var slot = audioSlot(SlotPreferences(mic: true))
        XCTAssertNil(micStatusChip(slot), "unbound, nothing is armed")
        slot.audio = ControllerAudioState(plan: armedPlan(), micLed: .pulse)
        let live = try XCTUnwrap(micStatusChip(slot))
        XCTAssertEqual(live.label, "Mic live")
        XCTAssertTrue(live.on)
        XCTAssertEqual(live.help, "Microphone is live. Click to mute it.")
        XCTAssertEqual(micLampChip(slot)?.help, "Mic lamp · Pulse")
        slot.audio = ControllerAudioState(plan: armedPlan(muted: true), micLed: .on)
        let muted = try XCTUnwrap(micStatusChip(slot))
        XCTAssertEqual(muted.label, "Mic muted")
        XCTAssertFalse(muted.on)
        XCTAssertEqual(muted.help, "Microphone muted. Click to unmute it.")
        XCTAssertEqual(micLampChip(slot)?.help, "Mic lamp · On")
        XCTAssertEqual(micLampChip(slot)?.on, true)
        slot.audio = ControllerAudioState(plan: armedPlan(), micLed: .off)
        XCTAssertNil(micLampChip(slot), "an unlit lamp is no chip")
        slot.audio = ControllerAudioState(plan: .silent, micLed: nil)
        XCTAssertNil(micStatusChip(slot), "a silent plan arms nothing")
    }

    func testTheGlobalSwitchesCoverOnlyTheThreeForwardedFeatures() {
        let allOff = ForwardingFlags(motion: false, touchpad: false, rumble: false, lightbar: false, mic: false, speaker: false)
        XCTAssertFalse(globallyAllowed(.motion, allOff))
        XCTAssertFalse(globallyAllowed(.rumble, allOff))
        XCTAssertFalse(globallyAllowed(.touchpad, allOff))
        XCTAssertTrue(globallyAllowed(.mic, allOff))
        XCTAssertTrue(globallyAllowed(.speaker, allOff))
    }

    func testTheSwitchValuesReadBothSides() {
        XCTAssertFalse(switchValue(.motion, ForwardingFlags(motion: false)))
        XCTAssertTrue(switchValue(.rumble, ForwardingFlags(motion: false)))
        XCTAssertFalse(switchValue(.touchpad, SlotPreferences(touchpad: .off)))
        XCTAssertTrue(switchValue(.touchpad, SlotPreferences(touchpad: .mouse)), "the mouse is the touchpad sent, as the mouse")
        XCTAssertTrue(switchValue(.motion, SlotPreferences(touchpad: .off)))
    }

    // MARK: - The touchpad's pick

    private func probed(mouseControl: Bool) -> HostProbeFacts {
        HostProbeFacts(mouseControl: mouseControl, rumble: true, mic: false, speaker: false)
    }

    func testTheTouchpadChipReadsThePickAndSaysWhereTheMouseGoes() throws {
        let chips = capabilityChips(for: slot(SlotPreferences(touchpad: .mouse)), ForwardingFlags())
        let touchpad = try chip("Touchpad", in: chips)
        XCTAssertTrue(touchpad.on)
        XCTAssertEqual(
            touchpad.help,
            "The touchpad moves the host’s mouse; the pad’s click is the left button. Click to turn it off for this controller."
        )
        XCTAssertFalse(try chip("Touchpad", in: capabilityChips(for: slot(SlotPreferences(touchpad: .off)), ForwardingFlags())).on)
    }

    func testThePickerOffersTheMouseOnlyWithTheHostsWord() {
        var bound = slot()
        bound.boundConnectionId = "sat"
        XCTAssertEqual(touchpadPickOptions(bound).map(\.label), ["Off", "Pad", "Mouse"])
        XCTAssertEqual(touchpadPickOptions(bound).map(\.enabled), [true, true, false], "an unprobed host has not spoken")
        bound.hostProbe = probed(mouseControl: true)
        XCTAssertEqual(touchpadPickOptions(bound).map(\.enabled), [true, true, true])
        bound.hostProbe = probed(mouseControl: false)
        XCTAssertEqual(touchpadPickOptions(bound).map(\.enabled), [true, true, false])
    }

    func testTheDetailSaysWhereTheTouchpadGoes() {
        var bound = slot()
        bound.hostProbe = probed(mouseControl: false)
        XCTAssertEqual(touchpadPickDetail(bound, ForwardingFlags()), "Forwards this pad’s touchpad to the game as a touchpad.")
        XCTAssertEqual(touchpadPickDetail(bound, ForwardingFlags(touchpad: false)), "Switched off in Settings.")
        bound.preferences.touchpad = .off
        XCTAssertEqual(touchpadPickDetail(bound, ForwardingFlags()), "Touchpad routing is off for this binding.")
        bound.preferences.touchpad = .mouse
        XCTAssertEqual(touchpadPickDetail(bound, ForwardingFlags()), "The host doesn’t carry Mouse.")
        bound.hostProbe = probed(mouseControl: true)
        XCTAssertEqual(
            touchpadPickDetail(bound, ForwardingFlags()),
            "The touchpad moves the host’s mouse; the pad’s click is the left button."
        )
    }
}
