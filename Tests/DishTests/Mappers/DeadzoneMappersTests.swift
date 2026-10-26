// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import DishEngine
import XCTest
@testable import Dish

/// Dead zones & motion: the sliders read what is stored or the defaults,
/// the readouts are percentages, a pad without a gyroscope says so, and a
/// pad that left is named missing.
final class DeadzoneMappersTests: XCTestCase {

    private typealias Fix = MapperFixtures

    private func card(_ facts: ShellFacts = ShellFacts(), slot: ControllerSlot = Fix.pad()) throws -> DeadzoneCardState {
        guard case let .pad(card) = deadzonePageState(slotId: "pad", slots: [slot], facts: facts).content else {
            return try XCTUnwrap(nil, "a card for the pad")
        }
        return card
    }

    func testAPadThatLeftIsMissing() {
        let state = deadzonePageState(slotId: "pad", slots: [], facts: ShellFacts())
        XCTAssertEqual(state.content, .missing(title: "No controllers connected", body: "Connect a controller to adjust its dead zones."))
        XCTAssertEqual(state.footnote, "Overrides are stored per device and take effect immediately.")
    }

    func testAPadNeverTunedReadsTheDefaults() throws {
        let card = try card()
        XCTAssertEqual(card.stick, DeadzoneSliderState(label: "Stick dead zone", percent: 10, readout: "10%", maxPercent: 30))
        XCTAssertEqual(card.trigger, DeadzoneSliderState(label: "Trigger dead zone", percent: 5, readout: "5%", maxPercent: 30))
        XCTAssertEqual(card.reset, "Reset to defaults")
        XCTAssertEqual(card.resetHelp, "Reset dead zones for DualSense")
    }

    func testAStoredTuningIsWhatTheSlidersRead() throws {
        var facts = ShellFacts()
        facts.deadzones = ["pad": DeadzoneSetting(stickPercent: 20, triggerPercent: 0)]
        let card = try card(facts)
        XCTAssertEqual(card.stick.percent, 20)
        XCTAssertEqual(card.trigger.readout, "0%")
    }

    func testAPadWithAGyroCarriesItsMotionSwitch() throws {
        var pad = Fix.pad()
        pad.preferences.motion = false
        XCTAssertEqual(
            try card(slot: pad).motion,
            .toggle(title: "Forward motion (gyro)", detail: "Send gyroscope and accelerometer readings to the host.", on: false)
        )
        XCTAssertEqual(try card(slot: pad).gyro.text, "Gyro")
    }

    func testAPadWithoutAGyroSaysWhyThereIsNoSwitch() throws {
        let bare = ControllerSlot(id: "pad", name: "Pad")
        let card = try card(slot: bare)
        XCTAssertEqual(card.motion, .unavailable("Motion forwarding unavailable — this device has no gyroscope."))
        XCTAssertEqual(card.gyro.text, "No gyro")
        XCTAssertTrue(card.gyro.look.absent)
    }
}
