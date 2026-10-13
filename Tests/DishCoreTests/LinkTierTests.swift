// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import XCTest
@testable import DishCore

/// One ladder across the clients: a satellite is Fastest, a Moonlight host
/// Fast, a Bluetooth pad Basic, and the rank sorts best-first.
final class LinkTierTests: XCTestCase {

    func testEachKindHasItsRung() {
        XCTAssertEqual(linkTierFor(.satellite), .fastest)
        XCTAssertEqual(linkTierFor(.moonlight), .fast)
        XCTAssertEqual(linkTierFor(.bluetooth), .basic)
    }

    func testTheRankSortsBestFirst() {
        let sorted = [LinkTier.basic, .fastest, .fast].sorted { linkTierRank($0) < linkTierRank($1) }
        XCTAssertEqual(sorted, [.fastest, .fast, .basic])
    }
}
