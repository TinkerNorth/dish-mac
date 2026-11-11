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

    func testACardCarriesItsPadsPathPlayerAndCheck() throws {
        var facts = ShellFacts()
        var path = SlotInputPath(source: .direct, reason: .directByModel)
        path.playerNumber = 2
        facts.inputPaths["pad"] = path
        guard case let .cards(cards) = controllersPageState(slots: [Fix.pad()], facts: facts).content else {
            return XCTFail("a card per pad")
        }
        let state = try XCTUnwrap(cards.first?.path)
        XCTAssertEqual(state.player, "Player 2")
        XCTAssertEqual(state.path, "Direct")
        XCTAssertEqual(state.prompt, "Press any button on this controller")
        XCTAssertEqual(state.check.link, "Not responding?")
        XCTAssertNil(card(Fix.pad()).path, "no facts yet, no path block")
    }

    func testACardLightsWhileItsPadReportsInput() {
        XCTAssertEqual(controllerCard(Fix.pad(), InputTelemetry(reporting: ["pad"])).stroke, DishTheme.primary)
        XCTAssertEqual(controllerCard(Fix.pad(), InputTelemetry(reporting: ["other"])).stroke, DishTheme.cardStroke)
    }

    func testAGuessedDirectPadWearsTheChipAndItsMenuChecksItsButtons() throws {
        var facts = ShellFacts()
        var path = SlotInputPath(source: .direct, reason: .macOSCannotRead)
        path.layoutGuessed = true
        path.remappable = true
        facts.inputPaths["pad"] = path
        guard case let .cards(cards) = controllersPageState(slots: [Fix.pad()], facts: facts).content else {
            return XCTFail("a card per pad")
        }
        let card = try XCTUnwrap(cards.first)
        XCTAssertEqual(card.layoutChip?.text, "Layout guessed")
        XCTAssertEqual(card.menu, [.checkButtons("Check the buttons"), .helpSupport("Help support this controller")])
        XCTAssertEqual(card.menuLabel, "More actions")
        XCTAssertNil(self.card(Fix.pad()).layoutChip)
        XCTAssertEqual(self.card(Fix.pad()).menu, [], "a pad macOS reads has no menu")
    }

    // MARK: - Offers to read a pad directly

    private func offer(_ standing: DirectOfferStanding) -> DirectOffer {
        DirectOffer(id: "hid:28de:1102", name: "Valve Steam Controller", standing: standing)
    }

    func testAnOfferedPadSaysWhatReadingItDoesAndOffersUseDirect() {
        let card = directOfferCard(offer(.offered(asksInputMonitoring: false)))
        XCTAssertEqual(card.id, "hid:28de:1102")
        XCTAssertEqual(card.title, "Valve Steam Controller")
        XCTAssertEqual(card.message, "Dish can read this controller directly. While it does, the controller’s keyboard and mouse are off.")
        XCTAssertNil(card.hint)
        XCTAssertEqual(card.actions, [.useDirect("Use Direct")])
    }

    func testAPadWhoseInterfaceCarriesItsKeyboardWarnsThatMacOSAsksFirst() {
        let card = directOfferCard(offer(.offered(asksInputMonitoring: true)))
        XCTAssertTrue(card.message.hasSuffix("macOS asks for Input Monitoring first, because the controller also acts as a keyboard."))
    }

    func testARefusedPadSaysWhyAndOpensInputMonitoringOrHandsItBack() {
        let card = directOfferCard(offer(.refused(.inputMonitoring)))
        XCTAssertEqual(card.hint, "macOS has not let Dish read this controller.")
        XCTAssertEqual(card.message, "Allow Dish under Privacy & Security › Input Monitoring, then quit and reopen Dish.")
        guard case let .openSettings(link) = card.actions.first else { return XCTFail("System Settings first") }
        XCTAssertEqual(link.title, "Open System Settings")
        XCTAssertEqual(link.url?.absoluteString, "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
        XCTAssertEqual(card.actions.last, .stopReading("Stop reading directly"))
    }

    func testAPadThatWouldNotOpenNamesTheLikelyCauseAndHandsItBack() {
        let card = directOfferCard(offer(.refused(.busy)))
        XCTAssertEqual(card.hint, "Dish couldn’t open this controller; another app may be using it.")
        XCTAssertEqual(card.message, "Quit that app, or unplug the controller and plug it back in.")
        XCTAssertEqual(card.actions, [.stopReading("Stop reading directly")])
    }

    func testAReceiverWithNoControllerSaysWhatItWaitsFor() {
        let card = directOfferCard(offer(.waitingForController))
        XCTAssertEqual(card.message, "Dish is reading this receiver directly. Turn on a controller paired with it.")
        XCTAssertNil(card.hint)
        XCTAssertEqual(card.actions, [.stopReading("Stop reading directly")])
    }

    func testOffersFollowThePadsAndReplaceTheEmptyState() {
        var facts = ShellFacts()
        facts.directOffers = [offer(.offered(asksInputMonitoring: false))]
        let alone = controllersPageState(slots: [], facts: facts)
        XCTAssertEqual(alone.content, .cards([]), "an offer is something to show")
        XCTAssertEqual(alone.offers.map(\.id), ["hid:28de:1102"])
        let beside = controllersPageState(slots: [Fix.pad()], facts: facts)
        guard case let .cards(cards) = beside.content else { return XCTFail("the pads first") }
        XCTAssertEqual(cards.map(\.id), ["pad"])
        XCTAssertEqual(beside.offers.count, 1)
        XCTAssertEqual(controllersPageState(slots: [], facts: ShellFacts()).offers, [])
    }

    func testEachOfferActionHasItsOwnIdentity() {
        let settings = SettingsLinkState(title: "Open System Settings", url: nil)
        let ids = [DirectOfferAction.useDirect("a"), .openSettings(settings), .stopReading("b")].map(\.id)
        XCTAssertEqual(Set(ids).count, 3)
    }
}
