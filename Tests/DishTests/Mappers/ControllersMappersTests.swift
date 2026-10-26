// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import DishEngine
import XCTest
@testable import Dish

/// Controllers' cards: the family and its measured rate, the binding's
/// hand-off, the device chips, the microphone's control, the motion rate,
/// the dead zones and the footer.
final class ControllersMappersTests: XCTestCase {

    private typealias Fix = MapperFixtures

    private func card(_ slot: ControllerSlot, rates: PadRates? = nil) -> ControllerCardState {
        controllerCard(slot, InputTelemetry(pads: rates.map { ["pad": $0] } ?? [:]))
    }

    func testControllersWithNonePlugInSaysSo() {
        let state = controllersPageState(slots: [], facts: ShellFacts())
        XCTAssertEqual(state.content, .empty(title: "No controllers connected", body: "Plug one in, then pick where it goes"))
        XCTAssertFalse(state.registering)
    }

    func testControllersListsACardPerPad() {
        guard case let .cards(cards) = controllersPageState(slots: [Fix.pad()], facts: ShellFacts()).content else {
            return XCTFail("a card per pad")
        }
        XCTAssertEqual(cards.map(\.id), ["pad"])
    }

    func testABoundPadHandsOffToItsBindingAndReadsItsRates() {
        let card = card(Fix.pad(boundTo: Fix.den), rates: PadRates(reportHz: 250, motionHz: 100))
        XCTAssertEqual(card.binding, .bound(title: "Bound · Den ›"))
        XCTAssertEqual(card.link, "DualSense · 250 Hz")
        XCTAssertEqual(card.motionRate, "Motion 100 Hz")
        XCTAssertEqual(card.dot, DishTheme.success)
        XCTAssertEqual(card.deadZones, "Dead zones…")
    }

    func testAnUnboundPadOffersToBindAndReadsItsFamilyAloneBeforeAReport() {
        let card = card(Fix.pad())
        XCTAssertEqual(card.binding, .unbound(label: "not bound", action: "Bind…"))
        XCTAssertEqual(card.link, "DualSense")
        XCTAssertNil(card.motionRate)
        XCTAssertEqual(card.dot, DishTheme.muted)
    }

    func testTheChipsNamePresenceAndTheLightbarOnlyWhenPresent() {
        XCTAssertEqual(card(Fix.pad()).chips.map(\.text), ["Gyro", "Touchpad", "Lightbar"])
        let bare = ControllerSlot(id: "pad", name: "Pad")
        let chips = card(bare).chips
        XCTAssertEqual(chips.map(\.text), ["No gyro", "No touchpad"])
        XCTAssertTrue(chips.allSatisfy(\.look.absent))
    }

    func testTheBatteryChipReadsTheLevelInItsTint() throws {
        var pad = Fix.pad()
        pad.battery = BatteryReading(level: 10, state: .discharging)
        let battery = try XCTUnwrap(card(pad).chips.last)
        XCTAssertEqual(battery.text, "Battery 10%")
        XCTAssertEqual(battery.look.ink, DishTheme.error)
        XCTAssertEqual(battery.help, "Battery 10%")
    }

    func testTheMicControlAppearsOnceArmedAndAClickFlipsIt() {
        var pad = Fix.pad(boundTo: Fix.den)
        XCTAssertNil(card(pad).mic)
        pad.audio = ControllerAudioState(plan: Fix.armedPlan(), micLed: nil)
        XCTAssertEqual(card(pad).mic?.muteOnClick, true)
        XCTAssertEqual(card(pad).mic?.title, "Mic live")
        pad.audio = ControllerAudioState(plan: Fix.armedPlan(muted: true), micLed: nil)
        XCTAssertEqual(card(pad).mic?.muteOnClick, false)
    }

    func testTheFooterIsHomes() {
        var facts = ShellFacts()
        facts.telemetry = InputTelemetry(eventsPerSecond: 5, sendsPerSecond: 4, totalSent: 3)
        XCTAssertEqual(controllersPageState(slots: [], facts: facts).footer, telemetryFooter(facts.telemetry))
    }
}
