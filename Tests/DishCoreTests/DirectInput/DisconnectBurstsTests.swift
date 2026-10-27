// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import XCTest

/// "Keeps disconnecting": three drops of one pad within 60 s, one notice per
/// burst.
final class DisconnectBurstsTests: XCTestCase {

    private func drops(_ instants: [Int64], of identity: String = "pad", into bursts: inout DisconnectBursts) -> [Bool] {
        instants.map { bursts.recordDrop(identity, nowMs: $0) }
    }

    func testTheRuleIsThreeDropsInSixtySeconds() {
        XCTAssertEqual(DisconnectBurstRule.drops, 3)
        XCTAssertEqual(DisconnectBurstRule.windowMs, 60000)
    }

    func testTheThirdDropInsideTheWindowIsNoticedOnce() {
        var bursts = DisconnectBursts()
        XCTAssertEqual(drops([0, 10000, 20000], into: &bursts), [false, false, true])
    }

    func testThreeDropsJustInsideTheWindowAreABurst() {
        var bursts = DisconnectBursts()
        XCTAssertEqual(drops([0, 10000, 59999], into: &bursts), [false, false, true])
    }

    func testFurtherDropsInTheSameBurstAreNotNoticedAgain() {
        var bursts = DisconnectBursts()
        XCTAssertEqual(drops([0, 10000, 20000, 30000, 65000, 75000], into: &bursts), [false, false, true, false, false, false])
    }

    func testThreeDropsSpreadWiderThanTheWindowAreNoBurst() {
        var bursts = DisconnectBursts()
        XCTAssertEqual(drops([0, 30000, 60000], into: &bursts), [false, false, false], "the drop at 0 has left the window at 60 s")
        XCTAssertEqual(bursts.recentDrops["pad"], [30000, 60000])
    }

    func testABurstEndsWhenItsDropsThinOutAndTheNextOneIsNoticedAgain() {
        var bursts = DisconnectBursts()
        XCTAssertEqual(drops([0, 1000, 2000], into: &bursts), [false, false, true])
        XCTAssertEqual(drops([200_000], into: &bursts), [false])
        XCTAssertFalse(bursts.noticed.contains("pad"))
        XCTAssertEqual(drops([201_000, 202_000], into: &bursts), [false, true])
    }

    func testEachPadIdentityIsCountedApart() {
        var bursts = DisconnectBursts()
        XCTAssertEqual(drops([0, 1000], of: "a", into: &bursts), [false, false])
        XCTAssertEqual(drops([2000, 3000], of: "b", into: &bursts), [false, false])
        XCTAssertEqual(drops([4000], of: "a", into: &bursts), [true])
        XCTAssertEqual(drops([5000], of: "b", into: &bursts), [true])
    }
}
