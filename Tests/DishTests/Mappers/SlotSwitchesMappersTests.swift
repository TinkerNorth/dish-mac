// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

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
        let chips = capabilityChips(for: slot(SlotPreferences(touchpad: true)), ForwardingFlags(touchpad: false))
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

    func testTheSwitchValuesReadBothSides() {
        XCTAssertFalse(switchValue(.motion, ForwardingFlags(motion: false)))
        XCTAssertTrue(switchValue(.rumble, ForwardingFlags(motion: false)))
        XCTAssertFalse(switchValue(.touchpad, SlotPreferences(touchpad: false)))
        XCTAssertTrue(switchValue(.motion, SlotPreferences(touchpad: false)))
    }
}
