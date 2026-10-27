// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import XCTest

/// A GameController controller of a Direct-by-model pad waits the settle
/// window for a lane of its model; with none it falls back to Standard and
/// stays there for the connection, and the pad's decision says why.
final class CarrierFallbackTests: XCTestCase {

    private let pro = directModel(vendorId: 0x057E, productId: 0x2009)
    private let n64 = directModel(vendorId: 0x057E, productId: 0x2019)

    func testTheSettleWindowIsTwoSeconds() {
        XCTAssertEqual(CarrierFallbackRule.settleMs, 2000)
    }

    func testACarrierWithNoLaneWaitsUntilTheWindowClosesThenFallsBack() {
        XCTAssertEqual(standCarrier(.waiting, lanesOfModel: 0, windowClosed: false), .waiting)
        XCTAssertEqual(standCarrier(.waiting, lanesOfModel: 0, windowClosed: true), .fellBack)
    }

    func testALaneBeforeTheWindowClosesKeepsTheCarrierACarrier() {
        XCTAssertEqual(standCarrier(.waiting, lanesOfModel: 1, windowClosed: false), .followsLanes)
        XCTAssertEqual(standCarrier(.waiting, lanesOfModel: 2, windowClosed: true), .followsLanes, "a lane at the deadline still counts")
    }

    func testTheStandingIsStickyForTheConnection() {
        XCTAssertEqual(standCarrier(.fellBack, lanesOfModel: 1, windowClosed: true), .fellBack, "a late lane moves nothing")
        XCTAssertEqual(standCarrier(.followsLanes, lanesOfModel: 0, windowClosed: true), .followsLanes, "a lane that left moves nothing")
    }

    func testAPadWhoseCarrierFellBackIsStandardBecauseDishCouldNotReadIt() {
        for model in [pro, n64] {
            var facts = PadPathFacts(model: model, decodable: false, gameController: .shows, stored: nil)
            facts.fellBackToStandard = true
            XCTAssertEqual(decidePath(facts), .forward(.standard, .dishCouldNotRead))
            facts.gameController = .pending
            XCTAssertEqual(decidePath(facts), .forward(.standard, .dishCouldNotRead), "nothing to wait for: macOS already reads it")
        }
    }

    func testAStoredStandardPickStillNamesThePickAfterAFallback() {
        var facts = PadPathFacts(model: pro, decodable: true, gameController: .shows, stored: .standard)
        facts.fellBackToStandard = true
        XCTAssertEqual(decidePath(facts), .forward(.standard, .userPicked))
    }

    func testALaneThatArrivesAfterTheFallbackMayStillBePickedDirect() {
        var facts = PadPathFacts(model: n64, decodable: true, gameController: .shows, stored: nil)
        facts.fellBackToStandard = true
        let connected = reduceInputSource(.initial, .connected(facts))
        XCTAssertEqual(connected.effects, [.forward(.standard)])
        XCTAssertTrue(connected.next.canPick(.direct), "the user's pick still wins")
        XCTAssertFalse(connected.next.canPick(.standard))
        let picked = reduceInputSource(connected.next, .userPicked(.direct))
        XCTAssertEqual(picked.next.phase, .forwarding(.direct))
        XCTAssertEqual(picked.effects, [.forward(.direct), .remember(.direct)])
    }
}
