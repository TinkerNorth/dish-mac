// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishEngine
import XCTest
@testable import Dish

final class SlotMappersTests: XCTestCase {

    private func server(_ live: LinkState, boundTo slotId: String? = nil) -> ConnectionSummary {
        ConnectionSummary(id: "c-\(live)", name: "Desk", live: live, boundSlotId: slotId)
    }

    private let slot = ControllerSlot(id: "pad", name: "DualSense")

    func testBindableExcludesConnectionsBoundToAnotherSlot() {
        let free = server(.ready)
        let mine = server(.connected, boundTo: "pad")
        let taken = server(.saved, boundTo: "other")
        XCTAssertEqual(bindableConnections(for: slot, in: [free, mine, taken]), [free, mine])
    }

    func testAMoonlightHostStaysBindableUntilItCarriesFourPads() {
        let three = ConnectionSummary(
            id: "moonlight:a",
            name: "PC",
            live: .ready,
            boundSlotId: "x",
            kind: .moonlight,
            boundSlotIds: ["x", "y", "z"]
        )
        let four = ConnectionSummary(
            id: "moonlight:b",
            name: "PC",
            live: .ready,
            boundSlotId: "x",
            kind: .moonlight,
            boundSlotIds: ["x", "y", "z", "w"]
        )
        let mine = ConnectionSummary(
            id: "moonlight:c",
            name: "PC",
            live: .ready,
            boundSlotId: "x",
            kind: .moonlight,
            boundSlotIds: ["x", "pad", "z", "w"]
        )
        XCTAssertEqual(bindableConnections(for: slot, in: [three, four, mine]), [three, mine])
    }

    func testAnUnboundSlotIsMuted() {
        XCTAssertEqual(slotDotColor(slot), DishTheme.muted)
    }

    func testABoundSlotFollowsItsServer() {
        var bound = slot
        bound.boundStatus = server(.connected)
        XCTAssertEqual(slotDotColor(bound), DishTheme.success)
    }

    func testAPadsLinkReadsAsItsFamilyBecauseGameControllerHidesTheTransport() {
        XCTAssertEqual(padFamilyName(.dualSense), "DualSense")
        XCTAssertEqual(padFamilyName(.dualShock4), "DualShock 4")
        XCTAssertEqual(padFamilyName(.xbox), "Xbox")
        XCTAssertEqual(padFamilyName(.other), "GameController")
    }

    func testAChipReadsWarningFirstThenOnAndOffAndAbsentIsDashed() {
        let on = CapabilityChipModel(label: "Gyro", on: true, available: true, help: "")
        XCTAssertEqual(capabilityChipLook(on), CapabilityChipLook(ink: DishTheme.primary, on: true, absent: false))
        let off = CapabilityChipModel(label: "Gyro", on: false, available: true, help: "")
        XCTAssertEqual(capabilityChipLook(off), CapabilityChipLook(ink: DishTheme.muted, on: false, absent: false))
        let absent = CapabilityChipModel(label: "No gyro", on: false, available: false, help: "")
        XCTAssertEqual(capabilityChipLook(absent), CapabilityChipLook(ink: DishTheme.muted, on: false, absent: true))
        let warned = CapabilityChipModel(label: "Mic", on: true, available: true, help: "", warning: true)
        XCTAssertEqual(capabilityChipLook(warned).ink, DishTheme.warning, "the warning outranks on")
    }

    func testAPadWithoutAnImuGetsTheAbsentMotionChip() {
        let chips = capabilityChips(.none, ForwardingFlags())
        XCTAssertEqual(chips, [
            CapabilityChipModel(
                label: "No gyro",
                on: false,
                available: false,
                help: "Motion not available — this controller has no gyroscope or accelerometer."
            )
        ])
    }

    func testTheMotionChipFollowsTheSwitch() {
        let caps = ControllerCapabilities(hasMotion: true)
        XCTAssertEqual(
            capabilityChips(caps, ForwardingFlags(motion: true)),
            [CapabilityChipModel(label: "Gyro", on: true, available: true, help: "Motion detected — forwarding to the host is on")]
        )
        XCTAssertEqual(
            capabilityChips(caps, ForwardingFlags(motion: false)),
            [CapabilityChipModel(label: "Gyro", on: false, available: true, help: "Motion detected — turned off in Settings")]
        )
    }

    func testOptionalChipsAppearOnlyForHardwareThePadHas() {
        let everything = ControllerCapabilities(hasMotion: true, hasTouchpad: true, hasRumble: true, hasLightbar: true)
        XCTAssertEqual(capabilityChips(everything, ForwardingFlags()).map(\.label), ["Gyro", "Touchpad", "Rumble", "Lightbar"])
        let rumbleOnly = ControllerCapabilities(hasRumble: true)
        XCTAssertEqual(capabilityChips(rumbleOnly, ForwardingFlags()).map(\.label), ["No gyro", "Rumble"])
    }

    func testTheLightbarChipNamesTheFeatureInItsTooltip() {
        let chips = capabilityChips(ControllerCapabilities(hasLightbar: true), ForwardingFlags(lightbar: false))
        XCTAssertEqual(chips.last, CapabilityChipModel(
            label: "Lightbar",
            on: false,
            available: true,
            help: "Light bar detected — turned off in Settings"
        ))
    }
}
