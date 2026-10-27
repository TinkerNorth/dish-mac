// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import XCTest

/// "Player 1", "Player 2": numbers by connection order, kept while
/// connected, the lowest free one reused.
final class PlayerNumbersTests: XCTestCase {

    func testPadsAreNumberedFromOneInConnectionOrder() {
        var players = PlayerNumbers()
        XCTAssertEqual(players.connect("a"), 1)
        XCTAssertEqual(players.connect("b"), 2)
        XCTAssertEqual(players.connect("c"), 3)
    }

    func testAPadThatConnectsAgainKeepsItsNumber() {
        var players = PlayerNumbers()
        XCTAssertEqual(players.connect("a"), 1)
        XCTAssertEqual(players.connect("b"), 2)
        XCTAssertEqual(players.connect("b"), 2, "a repeated arrival is not a second pad")
        XCTAssertEqual(players.numbers.count, 2)
    }

    func testAPadThatLeavesFreesItsNumberAndTheOthersKeepTheirs() {
        var players = PlayerNumbers()
        XCTAssertEqual(["a", "b", "c"].map { players.connect($0) }, [1, 2, 3])
        XCTAssertEqual(players.disconnect("b"), 2)
        XCTAssertNil(players.number(for: "b"))
        XCTAssertEqual(players.number(for: "a"), 1)
        XCTAssertEqual(players.number(for: "c"), 3)
    }

    func testTheLowestFreeNumberIsReused() {
        var players = PlayerNumbers()
        XCTAssertEqual(["a", "b", "c"].map { players.connect($0) }, [1, 2, 3])
        XCTAssertEqual(["a", "b"].map { players.disconnect($0) }, [1, 2])
        XCTAssertEqual(players.connect("d"), 1)
        XCTAssertEqual(players.connect("e"), 2)
        XCTAssertEqual(players.connect("f"), 4)
    }

    func testDisconnectingAPadThatHoldsNoNumberFreesNothing() {
        var players = PlayerNumbers()
        XCTAssertNil(players.disconnect("ghost"))
    }
}
