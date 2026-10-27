// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import DishEngine
import SwiftUI
import XCTest
@testable import Dish

/// Home's wiring diagram: a row per pad, the ghost "Bind…" card for a pad
/// with nowhere to go, the host node with the slot it holds, the wire's
/// caption from what is measured, the strip's chips and their clicks, the
/// invitation row and the footer.
final class HomeMappersTests: XCTestCase {

    private typealias Fix = MapperFixtures

    private func state(_ slots: [ControllerSlot], facts: ShellFacts = ShellFacts()) -> HomePageState {
        homePageState(HomeInputs(slots: slots, facts: facts))
    }

    private func row(_ slot: ControllerSlot, facts: ShellFacts = ShellFacts()) throws -> HomeRowState {
        let content = state([slot], facts: facts).content
        guard case let .rows(rows) = content else { return try XCTUnwrap(nil, "a row per pad, got \(content)") }
        return try XCTUnwrap(rows.first)
    }

    private func host(_ row: HomeRowState) throws -> (HostNodeState, HomeStripState) {
        guard case let .bound(host, strip) = row.destination else { return try XCTUnwrap(nil, "a bound row") }
        return (host, strip)
    }

    func testHomeWithNoControllerOffersTheSetupWalk() {
        let home = state([])
        let empty = HomeContent.empty(
            title: "Nothing set up yet",
            body: "Setup fills this diagram in, one answer at a time — and hands it back finished.",
            action: "Set up Dish ›"
        )
        XCTAssertEqual(home.content, empty)
        XCTAssertNil(home.setUp, "the empty state is the invitation")
    }

    func testAnUnboundPadIsAGhostRowUnderTheInvitation() throws {
        let row = try row(Fix.pad())
        XCTAssertEqual(row.destination, .ghost(GhostCardState(title: "Bind…", subtitle: "Choose a satellite for this pad")))
        XCTAssertEqual(row.pad, PadNodeState(name: "DualSense", detail: "DualSense · Unbound"))
        XCTAssertEqual(row.wire.label, "idle")
        XCTAssertFalse(row.wire.live)
        XCTAssertEqual(
            state([Fix.pad()]).setUp,
            SetUpCardState(title: "Set up a controller", subtitle: "Plug one in, then pick where it goes")
        )
    }

    func testTheInvitationStaysUnderTheRowsWithEveryPadBound() {
        XCTAssertNotNil(state([Fix.pad(boundTo: Fix.den)]).setUp, "another pad can always be set up, as on the desktops")
    }

    func testABoundPadDrawsTheHostAndWhichOfASatellitesFourSlotsItHolds() throws {
        let (host, _) = try host(row(Fix.pad(boundTo: Fix.den)))
        XCTAssertEqual(host.name, "Den")
        XCTAssertEqual(host.detail, "192.0.2.10 · slot 1 of 4", "a satellite carries four pads, as on the desktops")
        XCTAssertEqual(host.glyph, .satellite(.connected))
        XCTAssertEqual(host.chip, ChipState(text: "Online", color: DishTheme.success))
        XCTAssertEqual(host.dot, DishTheme.success)
    }

    func testAMoonlightPadSaysWhichOfTheFourSlotsItHolds() throws {
        let (host, _) = try host(row(Fix.pad(boundTo: Fix.host)))
        XCTAssertEqual(host.detail, "10.0.0.5 · slot 2 of 4")
        XCTAssertEqual(host.glyph, .moonlight)
    }

    func testALiveWireCarriesTheMeasuredRateAndLatency() throws {
        var den = Fix.den
        den.latencyMs = 1.24
        var facts = ShellFacts()
        facts.telemetry = InputTelemetry(pads: ["pad": PadRates(reportHz: 250, motionHz: 0)])
        let wire = try row(Fix.pad(boundTo: den), facts: facts).wire
        XCTAssertTrue(wire.live)
        XCTAssertFalse(wire.transmitting)
        XCTAssertEqual(wire.label, "250 Hz · 1.2 ms")
    }

    func testALiveWireWithNothingMeasuredSaysLive() throws {
        XCTAssertEqual(try row(Fix.pad(boundTo: Fix.den)).wire.label, "live")
    }

    func testAWireComingUpCrawlsButDoesNotReadLive() throws {
        var den = Fix.den
        den = ConnectionSummary(id: den.id, name: den.name, address: den.address, live: .connecting, boundSlotId: "pad")
        let wire = try row(Fix.pad(boundTo: den)).wire
        XCTAssertFalse(wire.live)
        XCTAssertTrue(wire.transmitting)
        XCTAssertEqual(wire.label, "idle")
    }

    func testAnApplyRunningForThePadCrawlsItsWire() throws {
        var facts = ShellFacts()
        facts.binding.draft = BindingDraft(slotId: "pad", original: BindingChoice())
        facts.binding.progress = .running(.binding)
        XCTAssertTrue(try row(Fix.pad(boundTo: Fix.loft), facts: facts).wire.transmitting)
    }

    func testTheStripLeadsWithTheTypeThenTheSwitchesWithTheirClicks() throws {
        var pad = Fix.pad(boundTo: Fix.den)
        let xbox = PickableType(id: 0, slug: "xbox360", name: "Xbox 360 Controller", shortName: "Xbox", description: "")
        pad.emulation = SlotEmulation(type: 0, isOverride: false, offered: [xbox])
        let (_, strip) = try host(row(pad))
        XCTAssertEqual(strip.title, "Binding")
        XCTAssertEqual(strip.editTitle, "Edit ›")
        XCTAssertEqual(strip.editHelp, "Configure binding")
        XCTAssertEqual(strip.chips.first?.text, "as Xbox")
        XCTAssertNil(strip.chips.first?.action, "the type is a fact; it is changed on Configure binding")
        let rumble = try XCTUnwrap(strip.chips.first { $0.text == "Rumble" })
        XCTAssertEqual(rumble.action, .setSwitch(.rumble, on: false), "a click turns an on switch off")
        let lightbar = try XCTUnwrap(strip.chips.first { $0.text == "Lightbar" })
        XCTAssertNil(lightbar.action, "the light bar has no switch of its own")
    }

    func testAGlobalSwitchOffLeavesTheChipUnclickable() throws {
        var facts = ShellFacts()
        facts.forwarding = ForwardingFlags(rumble: false)
        let (_, strip) = try host(row(Fix.pad(boundTo: Fix.den), facts: facts))
        XCTAssertNil(try XCTUnwrap(strip.chips.first { $0.text == "Rumble" }).action)
    }

    func testTheMicChipMutesItAndTheLampIsAFact() throws {
        var pad = Fix.pad(boundTo: Fix.den)
        pad.audio = ControllerAudioState(plan: Fix.armedPlan(), micLed: .on)
        let (_, strip) = try host(row(pad))
        XCTAssertEqual(try XCTUnwrap(strip.chips.first { $0.text == "Mic live" }).action, .setMicMuted(true))
        XCTAssertNil(try XCTUnwrap(strip.chips.first { $0.text == "Mic lamp" }).action)
    }

    func testTheFooterCarriesTheRatesAndTheTotal() {
        var facts = ShellFacts()
        facts.telemetry = InputTelemetry(eventsPerSecond: 250, sendsPerSecond: 248, totalSent: 9001)
        XCTAssertEqual(state([], facts: facts).footer, TelemetryFooterState(rates: "events/s 250   sends/s 248", total: "total 9,001"))
    }

    func testThePadNodeNamesTheBattery() throws {
        var pad = Fix.pad(boundTo: Fix.den)
        pad.battery = BatteryReading(level: 80, state: .discharging)
        XCTAssertEqual(try row(pad).pad.detail, "DualSense · Battery 80%")
    }

    func testTheBatteryWordFollowsItsState() {
        XCTAssertEqual(batteryChipText(BatteryReading(level: 100, state: .full)), "Battery full")
        XCTAssertEqual(batteryChipText(BatteryReading(level: 40, state: .charging)), "Battery 40% ↑")
        XCTAssertEqual(batteryChipText(BatteryReading(level: nil, state: .charging)), "Battery charging")
        XCTAssertEqual(batteryChipText(BatteryReading(level: 12, state: .unknown)), "Battery 12%")
        XCTAssertEqual(batteryChipText(BatteryReading(level: nil, state: .discharging)), "Battery level unknown")
    }

    func testARegisteringSatelliteShowsTheSpinner() {
        XCTAssertTrue(homePageState(HomeInputs(slots: [], facts: ShellFacts(), registering: true)).registering)
    }

    func testABoundRowIsACardAndTheGhostOnlyItsOutline() throws {
        let bound = try row(Fix.pad(boundTo: Fix.den))
        XCTAssertEqual(signalRowFill(bound.destination), DishTheme.surface)
        XCTAssertEqual(signalRowFill(.ghost(GhostCardState(title: "Bind…", subtitle: ""))), Color.clear)
    }

    func testAPadNodeNamesItsPlayerAndPathAndAsksForAButtonUntilProven() throws {
        var facts = ShellFacts()
        var path = SlotInputPath(source: .standard, reason: .dishCouldNotRead)
        path.playerNumber = 1
        facts.inputPaths["pad"] = path
        let unproven = try row(Fix.pad(), facts: facts).pad
        XCTAssertEqual(unproven.path, "Player 1 · Standard · Dish couldn’t read it directly, so macOS reads it")
        XCTAssertEqual(unproven.prompt, "Press any button on this controller")
        facts.inputPaths["pad"]?.proven = true
        XCTAssertNil(try row(Fix.pad(), facts: facts).pad.prompt, "the first real change takes the prompt away")
    }
}
