// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import XCTest
@testable import DishEngine

/// The input paths' pure rules: which controller carries a Direct pad's
/// output, and where a pad's check stands.
final class InputPathRulesTests: XCTestCase {

    func testTheCarriageRule() {
        let pro = directModel(vendorId: 0x057E, productId: 0x2009)
        let generic = directModel(vendorId: 0x2DC8, productId: 0x5006)
        let seat = CarrierSeat(id: "gc", hasRumble: true)
        XCTAssertEqual(outputCarriage(model: pro, carriers: [seat], padsOfModel: 1), OutputCarriage(carrierId: "gc", rumble: .carried))
        XCTAssertEqual(outputCarriage(model: pro, carriers: [], padsOfModel: 1).rumble, .noCarrier)
        XCTAssertEqual(outputCarriage(model: pro, carriers: [seat, seat], padsOfModel: 1).rumble, .ambiguous)
        XCTAssertEqual(outputCarriage(model: pro, carriers: [seat], padsOfModel: 2).rumble, .ambiguous)
        let quiet = CarrierSeat(id: "gc", hasRumble: false)
        XCTAssertEqual(
            outputCarriage(model: pro, carriers: [quiet], padsOfModel: 1),
            OutputCarriage(carrierId: "gc", rumble: .carrierHasNoMotors)
        )
        XCTAssertEqual(outputCarriage(model: generic, carriers: [seat], padsOfModel: 1).rumble, .notCarried)
        XCTAssertEqual(outputCarriage(model: nil, carriers: [seat], padsOfModel: 1).rumble, .notCarried)
    }

    func testTheCheckPhaseReadsTheRunningCheckBeforeTheLastVerdict() {
        let outcome = CheckOutcome(verdict: .dishReadsIt, offer: .none)
        XCTAssertEqual(checkPhase(nil, outcome: nil), .idle)
        XCTAssertEqual(checkPhase(nil, outcome: outcome), .concluded(.dishReadsIt, offer: CheckOffer.none))
        XCTAssertEqual(checkPhase(PadCheck(startedAtMs: 7), outcome: outcome), .running(sinceMs: 7))
    }
}
