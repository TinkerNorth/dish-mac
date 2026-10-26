// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// How a satellite's controller indices are handed out: four pads at most,
// as the desktops' "slot n of 4", each on the lowest index no bound pad holds.

import DishCore
import XCTest

final class SatelliteSlotsTests: XCTestCase {

    func testASatelliteCarriesFourPadsLikeTheDesktops() {
        XCTAssertEqual(SatelliteSlots.maxPerSatellite, 4)
    }

    func testTheFirstPadTakesIndexZero() {
        XCTAssertEqual(SatelliteSlots.lowestFreeIndex(taken: []), 0)
    }

    func testTheNextPadTakesTheLowestIndexNobodyHolds() {
        XCTAssertEqual(SatelliteSlots.lowestFreeIndex(taken: [0, 1]), 2)
        XCTAssertEqual(SatelliteSlots.lowestFreeIndex(taken: [0, 2, 3]), 1, "a freed index is reused first")
        XCTAssertEqual(SatelliteSlots.lowestFreeIndex(taken: [1, 2, 3]), 0)
    }

    func testAFullSatelliteHasNoFreeIndex() {
        XCTAssertNil(SatelliteSlots.lowestFreeIndex(taken: [0, 1, 2, 3]))
    }

    func testAnIndexBeyondTheCapNeverCountsAsHeld() {
        XCTAssertEqual(SatelliteSlots.lowestFreeIndex(taken: [0, 1, 2, 7]), 3)
    }
}
