// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Combine
import DishCore
import XCTest
@testable import DishEngine

/// A Steam Controller on the input paths: offered and left closed until the
/// user picks Direct, then claimed, shown and remembered; handed back on a
/// Standard pick; hidden with its reason when macOS refuses the open; a
/// receiver's slots one offer, each a pad only while its controller is
/// there; and every claim given back before the app quits.
@MainActor
final class InputPathsSteamTests: XCTestCase {

    private static let wired = "hid:28de:1102"
    private static let triton = "hid:28de:1302"
    private static let dongle = "hid:28de:1142"
    private static let dongleSecond = "hid:28de:1142#1"

    private var suite: String!
    private var defaults: UserDefaults!
    private var reader: FakeHidPadReader!
    private var scheduler: ManualPathScheduler!
    private var host: FakePathHost!
    private var choices: UsbPathChoiceStore!
    private var paths: InputPaths!
    private let processor = GamepadInputProcessor()

    override func setUp() {
        super.setUp()
        suite = "dish.test.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        reader = FakeHidPadReader()
        scheduler = ManualPathScheduler()
        host = FakePathHost()
        choices = UsbPathChoiceStore(defaults: defaults)
        paths = InputPaths(choices: choices, reader: reader, scheduler: scheduler)
        paths.host = host
        paths.start(processor: processor)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    /// GameController's settle says no, as it does for every Valve pad today.
    @discardableResult
    private func arrive(
        productId: Int,
        slotId: String,
        interfaceNumber: Int? = 2,
        inputMonitoring: Bool = false,
        output: DirectOutput? = nil,
        shows: Bool = false
    ) throws -> HidPadLane {
        let wiring = try XCTUnwrap(reader.wiring)
        let properties = DirectFixtures.valveProperties(
            productId: productId, interfaceNumber: interfaceNumber, requiresInputMonitoring: inputMonitoring
        )
        let lane = try DirectFixtures.lane(DirectFixtures.candidate(properties), slotId: slotId, wiring: wiring, output: output)
        paths.hidPadArrived(HidPadArrival(slotId: slotId, lane: lane, probe: GameControllerProbe { shows }))
        scheduler.advance(ms: 100)
        return lane
    }

    private func offered(_ id: String, _ name: String, asks: Bool = false) -> DirectOffer {
        DirectOffer(id: id, name: name, standing: .offered(asksInputMonitoring: asks))
    }

    private func storedChoices() -> [String: String]? {
        defaults.dictionary(forKey: UsbPathChoiceStore.choicesKey) as? [String: String]
    }

    // MARK: - The offer

    func testASteamControllerIsOfferedAndNeitherOpenedNorShownUntilPicked() throws {
        try arrive(productId: 0x1102, slotId: Self.wired)
        XCTAssertNil(host.directSlots[Self.wired])
        XCTAssertNil(paths.state[Self.wired], "no path facts for a pad nobody reads")
        XCTAssertEqual(reader.claims, [], "never opened, never sent anything")
        XCTAssertEqual(paths.offers.state, [offered(Self.wired, "Valve Steam Controller")])
    }

    func testUseDirectClaimsItShowsItsPadAndRemembersThePick() throws {
        try arrive(productId: 0x1102, slotId: Self.wired)
        XCTAssertTrue(paths.pick(slotId: Self.wired, .direct))
        XCTAssertEqual(reader.claims, [.claim(Self.wired)])
        let slot = try XCTUnwrap(host.directSlots[Self.wired])
        XCTAssertTrue(slot.capabilities.hasMotion)
        XCTAssertFalse(slot.capabilities.hasRumble, "the 2015 pad has no motors")
        XCTAssertTrue(slot.capabilities.hasBattery, "the Mac's stands in")
        XCTAssertTrue(slot.capabilities.hasExtendedButtons, "the grips, the trigger clicks and the left pad's click")
        let facts = try XCTUnwrap(paths.state[Self.wired])
        XCTAssertEqual(facts.source, .direct)
        XCTAssertEqual(facts.reason, .userPicked)
        XCTAssertEqual(facts.picks, [.standard], "it can be handed back")
        XCTAssertFalse(facts.capturable, "no support capture: its own decoders read it")
        XCTAssertFalse(facts.remappable)
        XCTAssertEqual(paths.offers.state, [])
        XCTAssertEqual(storedChoices(), ["28de:1102": "direct"])
    }

    func testAStoredPickIsClaimedAtOnceOnTheNextConnect() throws {
        choices.setChoice(.direct, vendorId: 0x28DE, productId: 0x1102)
        try arrive(productId: 0x1102, slotId: Self.wired)
        XCTAssertEqual(reader.claims, [.claim(Self.wired)])
        XCTAssertNotNil(host.directSlots[Self.wired])
    }

    func testHandingItBackReleasesItAndOffersItAgain() throws {
        try arrive(productId: 0x1102, slotId: Self.wired)
        XCTAssertTrue(paths.pick(slotId: Self.wired, .direct))
        XCTAssertTrue(paths.pick(slotId: Self.wired, .standard))
        XCTAssertEqual(reader.claims, [.claim(Self.wired), .unclaim(Self.wired)])
        XCTAssertNil(host.directSlots[Self.wired])
        XCTAssertEqual(paths.offers.state, [offered(Self.wired, "Valve Steam Controller")])
        XCTAssertEqual(storedChoices(), ["28de:1102": "standard"], "not read on its next connect")
    }

    func testAPadGameControllerShowsIsLeftToIt() throws {
        try arrive(productId: 0x1102, slotId: Self.wired, shows: true)
        XCTAssertEqual(reader.released, [Self.wired])
        XCTAssertEqual(paths.offers.state, [])
    }

    // MARK: - Input Monitoring

    func testA2026PadsOfferSaysMacOSAsksForInputMonitoringFirst() throws {
        try arrive(productId: 0x1302, slotId: Self.triton, interfaceNumber: nil, inputMonitoring: true)
        XCTAssertEqual(paths.offers.state, [offered(Self.triton, "Valve Steam Controller (2026)", asks: true)])
    }

    func testARefusedOpenHidesThePadAndTheOfferSaysWhy() throws {
        try arrive(productId: 0x1302, slotId: Self.triton, interfaceNumber: nil, inputMonitoring: true)
        XCTAssertTrue(paths.pick(slotId: Self.triton, .direct))
        paths.claimRefused(Self.triton, .inputMonitoring)
        XCTAssertNil(host.directSlots[Self.triton])
        XCTAssertNil(paths.state[Self.triton])
        let refused = DirectOffer(id: Self.triton, name: "Valve Steam Controller (2026)", standing: .refused(.inputMonitoring))
        XCTAssertEqual(paths.offers.state, [refused])
        XCTAssertEqual(storedChoices(), ["28de:1302": "direct"], "granted and reopened, Dish reads it at once")
    }

    func testARefusedPadHandedBackIsOfferedAgainAndAFreshPickClaimsAgain() throws {
        try arrive(productId: 0x1302, slotId: Self.triton, interfaceNumber: nil, inputMonitoring: true)
        XCTAssertTrue(paths.pick(slotId: Self.triton, .direct))
        paths.claimRefused(Self.triton, .busy)
        XCTAssertTrue(paths.pick(slotId: Self.triton, .standard))
        XCTAssertEqual(paths.offers.state, [offered(Self.triton, "Valve Steam Controller (2026)", asks: true)])
        XCTAssertTrue(paths.pick(slotId: Self.triton, .direct))
        XCTAssertEqual(reader.claims, [.claim(Self.triton), .unclaim(Self.triton), .claim(Self.triton)])
        XCTAssertNotNil(host.directSlots[Self.triton], "the refusal went with the hand-back")
    }

    func testThe2026PadDrivesItsOwnRumble() throws {
        choices.setChoice(.direct, vendorId: 0x28DE, productId: 0x1302)
        try arrive(productId: 0x1302, slotId: Self.triton, interfaceNumber: nil)
        XCTAssertEqual(host.directSlots[Self.triton]?.capabilities.hasRumble, true)
        XCTAssertEqual(host.directSlots[Self.triton]?.capabilities.hasExtendedButtons, true, "QAM, the paddles, the clicks, the touches")
        XCTAssertEqual(paths.state[Self.triton]?.rumble, .ownReport)
    }

    // MARK: - A receiver

    func testAReceiversSlotsMakeOneOfferAndWaitForAController() throws {
        try arrive(productId: 0x1142, slotId: Self.dongle, interfaceNumber: 1)
        try arrive(productId: 0x1142, slotId: Self.dongleSecond, interfaceNumber: 2)
        XCTAssertEqual(paths.offers.state, [offered(Self.dongle, "Valve Steam Controller (dongle)")])
        XCTAssertTrue(paths.pick(slotId: Self.dongle, .direct))
        XCTAssertEqual(reader.claims, [.claim(Self.dongle), .claim(Self.dongleSecond)], "the pick is the model's")
        XCTAssertEqual(host.directSlots, [:], "no controller has shown up yet")
        let waiting = DirectOffer(id: Self.dongle, name: "Valve Steam Controller (dongle)", standing: .waitingForController)
        XCTAssertEqual(paths.offers.state, [waiting])
    }

    func testAControllerOnASlotIsAPadWhileItIsThere() throws {
        try arrive(productId: 0x1142, slotId: Self.dongle, interfaceNumber: 1)
        let second = try arrive(productId: 0x1142, slotId: Self.dongleSecond, interfaceNumber: 2)
        XCTAssertTrue(paths.pick(slotId: Self.dongle, .direct))
        feedReport(SteamReceiverEvent.wireless(0x02), to: second)
        drainMain()
        XCTAssertEqual(Array(host.directSlots.keys), [Self.dongleSecond])
        XCTAssertEqual(paths.offers.state, [], "a pad of the model is on the page")
        feedReport(SteamReceiverEvent.wireless(0x01), to: second)
        drainMain()
        XCTAssertEqual(host.directSlots, [:])
        XCTAssertEqual(paths.offers.state.map(\.standing), [.waitingForController])
    }

    // MARK: - Quitting

    func testQuittingGivesEveryPadReadOnAClaimBackBeforeItReturns() throws {
        let wiredOutput = FakeDirectOutput()
        let n64Output = FakeDirectOutput()
        try arrive(productId: 0x1102, slotId: Self.wired, output: wiredOutput)
        let wiring = try XCTUnwrap(reader.wiring)
        let candidate = try DirectFixtures.candidate(DirectFixtures.nintendoProperties(productId: 0x2019))
        let n64 = DirectFixtures.lane(candidate, slotId: "hid:057e:2019", wiring: wiring, output: n64Output)
        paths.hidPadArrived(HidPadArrival(slotId: "hid:057e:2019", lane: n64, probe: GameControllerProbe { true }))
        paths.releaseClaimsNow()
        XCTAssertEqual(wiredOutput.calls, [.releasedNow])
        XCTAssertEqual(n64Output.calls, [], "a pad read without a claim has nothing to give back")
    }

    // MARK: - The offer's standing

    func testAnOfferStandsForItsLanesInOrder() {
        XCTAssertNil(offerStanding(OfferLanes(shown: true, refusal: .busy, offered: true)), "a pad of the model is on the page")
        XCTAssertEqual(offerStanding(OfferLanes(refusal: .inputMonitoring, offered: true, reading: true)), .refused(.inputMonitoring))
        XCTAssertEqual(
            offerStanding(OfferLanes(offered: true, asksInputMonitoring: true, reading: true)),
            .offered(asksInputMonitoring: true)
        )
        XCTAssertEqual(offerStanding(OfferLanes(reading: true)), .waitingForController)
        XCTAssertNil(offerStanding(OfferLanes()), "macOS reads it, or nothing is decided yet")
    }
}

/// The 2015 receiver's wireless event: payload 0x01 disconnected, 0x02 connected.
private enum SteamReceiverEvent {
    static func wireless(_ payload: UInt8) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 64)
        bytes[0] = 0x01
        bytes[2] = 0x03
        bytes[3] = 0x01
        bytes[4] = payload
        return bytes
    }
}
