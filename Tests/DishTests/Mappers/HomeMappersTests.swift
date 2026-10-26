// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishEngine
import XCTest
@testable import Dish

final class HomeMappersTests: XCTestCase {

    func testHomeWithNoControllerSaysNothingIsSetUp() {
        let state = homePageState(slots: [], registering: false)
        XCTAssertEqual(state.list, .empty(title: "Nothing set up yet", body: "Plug one in, then pick where it goes"))
        XCTAssertEqual(state.section, "CONTROLLERS")
    }

    func testHomeListsEveryControllerAndWhetherOneIsRegistering() {
        let slot = ControllerSlot(id: "pad", name: "DualSense")
        let state = homePageState(slots: [slot], registering: true)
        XCTAssertEqual(state.list, .slots([slot]))
        XCTAssertTrue(state.registering)
    }
}
