// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import XCTest
@testable import DishCore

/// Controller numbers: lowest free, four at most, never two for one slot,
/// the mask that names the pads present, and the way back from a number.
final class MoonlightPadSlotsTests: XCTestCase {

    func testTheLowestFreeNumberFourAtMost() {
        var slots = MoonlightPadSlots()
        XCTAssertEqual(slots.assign("a"), 0)
        XCTAssertEqual(slots.assign("b"), 1)
        XCTAssertEqual(slots.assign("c"), 2)
        XCTAssertEqual(slots.assign("d"), 3)
        XCTAssertTrue(slots.isFull)
        XCTAssertNil(slots.assign("e"), "a session carries four pads and no more")
        XCTAssertEqual(slots.activeMask, 0b1111)
    }

    func testASlotKeepsItsNumberAndAReleasedNumberIsReused() {
        var slots = MoonlightPadSlots()
        XCTAssertEqual(slots.assign("a"), 0)
        XCTAssertEqual(slots.assign("b"), 1)
        XCTAssertNil(slots.assign("a"), "a live number is never handed out twice")
        XCTAssertEqual(slots.release("a"), 0)
        XCTAssertEqual(slots.activeMask, 0b0010)
        XCTAssertEqual(slots.assign("c"), 0, "the lowest free again")
        XCTAssertNil(slots.release("zzz"))
        XCTAssertEqual(slots.count, 2)
    }

    func testTheWayBackFromANumber() {
        var slots = MoonlightPadSlots()
        _ = slots.assign("a")
        _ = slots.assign("b")
        XCTAssertEqual(slots.slot(for: 1), "b")
        XCTAssertNil(slots.slot(for: 2))
        XCTAssertEqual(slots.number(for: "b"), 1)
        XCTAssertNil(slots.number(for: "c"))
        XCTAssertFalse(slots.isEmpty)
        XCTAssertTrue(MoonlightPadSlots().isEmpty)
        XCTAssertEqual(MoonlightPadSlots().activeMask, 0)
    }
}
