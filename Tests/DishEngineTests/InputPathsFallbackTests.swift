// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Combine
import DishCore
import XCTest
@testable import DishEngine

/// A GameController controller of a Direct-by-model pad that Dish's reader
/// never opened is not left silent: after the two-second settle window with
/// no lane of its model it is read through GameController, "Dish couldn't
/// read it directly", and a lane that turns up later moves nothing until a
/// reconnect or the user's pick.
@MainActor
final class InputPathsFallbackTests: XCTestCase {

    private static let pro = "hid:057e:2009"
    private static let proCarrier = "gc:Nintendo:Switch Pro Controller"
    private static let n64 = "hid:057e:2019"
    private static let n64Carrier = "gc:Nintendo:Switch N64 Controller"

    private var suite: String!
    private var defaults: UserDefaults!
    private var reader: FakeHidPadReader!
    private var scheduler: ManualPathScheduler!
    private var host: FakePathHost!
    private var paths: InputPaths!
    private let processor = GamepadInputProcessor()
    private var records: [InputPathRecord] = []
    private var bag = Set<AnyCancellable>()

    override func setUp() {
        super.setUp()
        suite = "dish.test.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        reader = FakeHidPadReader()
        scheduler = ManualPathScheduler()
        host = FakePathHost()
        paths = makePaths()
    }

    override func tearDown() {
        bag.removeAll()
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func makePaths() -> InputPaths {
        let made = InputPaths(choices: UsbPathChoiceStore(defaults: defaults), reader: reader, scheduler: scheduler) { 0 }
        made.host = host
        made.start(processor: processor)
        made.records.sink { [weak self] record in self?.records.append(record) }.store(in: &bag)
        return made
    }

    @discardableResult
    private func arrive(productId: Int, slotId: String) throws -> HidPadArrival {
        let wiring = try XCTUnwrap(reader.wiring)
        let candidate = try DirectFixtures.candidate(DirectFixtures.nintendoProperties(productId: productId))
        let lane = DirectFixtures.lane(candidate, slotId: slotId, wiring: wiring)
        let arrival = HidPadArrival(slotId: slotId, lane: lane, probe: GameControllerProbe { true })
        paths.hidPadArrived(arrival)
        return arrival
    }

    private func attach(_ id: String, category: String) -> PadGate {
        paths.gameControllerAttached(id: id, name: "Nintendo", category: category, hasRumble: true)
    }

    func testACarrierWithNoLaneIsReadThroughGameControllerAfterTwoSeconds() {
        let gate = attach(Self.proCarrier, category: "Switch Pro Controller")
        scheduler.advance(ms: CarrierFallbackRule.settleMs - 1)
        XCTAssertNil(gate.routed, "while it waits it publishes nothing")
        XCTAssertNil(paths.state[Self.proCarrier])
        XCTAssertNotEqual(host.carriersShown[Self.proCarrier], true)
        scheduler.advance(ms: 1)
        XCTAssertEqual(gate.routed, .standard)
        XCTAssertEqual(host.carriersShown[Self.proCarrier], true)
        let facts = paths.state[Self.proCarrier]
        XCTAssertEqual(facts?.source, .standard)
        XCTAssertEqual(facts?.reason, .dishCouldNotRead)
        XCTAssertEqual(facts?.proven, false, "the prompt to press a button shows")
        XCTAssertEqual(records.last, InputPathRecord(subject: "Nintendo", note: .chosen(.standard, .dishCouldNotRead)))
    }

    func testALaneBeforeTheWindowKeepsTheControllerACarrier() throws {
        let gate = attach(Self.proCarrier, category: "Switch Pro Controller")
        scheduler.advance(ms: 500)
        let arrival = try arrive(productId: 0x2009, slotId: Self.pro)
        scheduler.advance(ms: CarrierFallbackRule.settleMs)
        XCTAssertNil(gate.routed)
        XCTAssertEqual(host.carrierShowings[Self.proCarrier]?.contains(true), false, "never shown")
        XCTAssertEqual(arrival.lane.gate.routed, .direct)
        XCTAssertEqual(paths.state[Self.pro]?.reason, .directByModel)
    }

    func testALaneAfterTheFallbackMovesNothingAndPublishesNothing() throws {
        let gate = attach(Self.n64Carrier, category: "Switch N64 Controller")
        scheduler.advance(ms: CarrierFallbackRule.settleMs)
        let arrival = try arrive(productId: 0x2019, slotId: Self.n64)
        scheduler.advance(ms: 100)
        XCTAssertEqual(gate.routed, .standard, "sticky for the connection")
        let showings = try XCTUnwrap(host.carrierShowings[Self.n64Carrier])
        XCTAssertEqual(Array(showings.drop { !$0 }.prefix(1)), [true], "shown at the fallback")
        XCTAssertFalse(showings.drop { !$0 }.contains(false), "and never hidden since: no flapping")
        XCTAssertFalse(arrival.lane.gate.forwards(.direct), "no double input")
        XCTAssertFalse(arrival.lane.gate.pass(.direct, changed: true))
        XCTAssertNil(host.directSlots[Self.n64])
        XCTAssertNil(paths.state[Self.n64])
        XCTAssertEqual(paths.state[Self.n64Carrier]?.reason, .dishCouldNotRead)
        XCTAssertEqual(paths.state[Self.n64Carrier]?.picks, [.direct], "now that Dish can read it, Direct is on offer")
    }

    func testTheUsersPickStillWinsOverAFallback() throws {
        let gate = attach(Self.n64Carrier, category: "Switch N64 Controller")
        scheduler.advance(ms: CarrierFallbackRule.settleMs)
        let arrival = try arrive(productId: 0x2019, slotId: Self.n64)
        XCTAssertTrue(paths.pick(slotId: Self.n64Carrier, .direct))
        XCTAssertNil(gate.routed)
        XCTAssertEqual(host.carriersShown[Self.n64Carrier], false)
        XCTAssertEqual(arrival.lane.gate.routed, .direct)
        XCTAssertNotNil(host.directSlots[Self.n64])
    }

    func testAStoredStandardPickNamesThePickWhenTheCarrierFallsBack() {
        UsbPathChoiceStore(defaults: defaults).setChoice(.standard, vendorId: 0x057E, productId: 0x2009)
        paths = makePaths()
        let gate = attach(Self.proCarrier, category: "Switch Pro Controller")
        scheduler.advance(ms: CarrierFallbackRule.settleMs)
        XCTAssertEqual(gate.routed, .standard)
        XCTAssertEqual(paths.state[Self.proCarrier]?.reason, .userPicked)
    }

    func testAFallenBackCarrierThatLeavesTakesItsFactsAndItsDropWithIt() {
        let gate = attach(Self.proCarrier, category: "Switch Pro Controller")
        scheduler.advance(ms: CarrierFallbackRule.settleMs)
        paths.gameControllerDetached(id: Self.proCarrier, name: "Nintendo")
        XCTAssertNil(gate.routed)
        XCTAssertNil(paths.state[Self.proCarrier])
        let reattached = attach(Self.proCarrier, category: "Switch Pro Controller")
        XCTAssertNil(reattached.routed, "a reconnect waits the window again")
    }
}
