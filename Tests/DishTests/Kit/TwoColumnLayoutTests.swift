// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import XCTest
@testable import Dish

/// Settings goes to two columns at the desktops' breakpoint and not before.
final class TwoColumnLayoutTests: XCTestCase {

    func testTwoColumnsFromTheBreakpointUp() {
        XCTAssertEqual(TwoColumnLayout.columnCount(width: 979, breakpoint: 980), 1)
        XCTAssertEqual(TwoColumnLayout.columnCount(width: 980, breakpoint: 980), 2)
        XCTAssertEqual(TwoColumnLayout.columnCount(width: 1400, breakpoint: 980), 2)
    }

    func testTheBreakpointIsTheDesktops() {
        XCTAssertEqual(DishSize.wideBreakpoint, 980)
    }
}
