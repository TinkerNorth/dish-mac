// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishEngine
import XCTest
@testable import Dish

final class ControllersMappersTests: XCTestCase {

    func testControllersWithNonePlugInSaysSo() {
        let state = controllersPageState(slots: [], registering: false)
        XCTAssertEqual(state.list, .empty(title: "No controllers connected", body: "Plug one in, then pick where it goes"))
        XCTAssertFalse(state.registering)
    }

    func testControllersListsEveryPad() {
        let slot = ControllerSlot(id: "pad", name: "DualSense")
        XCTAssertEqual(controllersPageState(slots: [slot], registering: false).list, .slots([slot]))
    }
}
