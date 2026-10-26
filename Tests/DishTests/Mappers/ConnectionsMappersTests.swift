// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishEngine
import XCTest
@testable import Dish

final class ConnectionsMappersTests: XCTestCase {

    func testWithNothingFoundThePageSaysToScan() {
        let state = connectionsPageState(connections: [], discovered: [], scanning: true)
        XCTAssertEqual(state.rows, [])
        XCTAssertEqual(state.emptyHint, "Press Scan to look for servers on your LAN")
        XCTAssertTrue(state.scanning)
    }

    func testThePageListsKnownSatellitesThenTheNewlyFound() {
        let known = ConnectionSummary(id: "a", label: "Den", detail: "", live: .saved, boundSlotId: nil)
        let found = DiscoveredServer(name: "Desk", ip: "10.0.0.5")
        let state = connectionsPageState(connections: [known], discovered: [found], scanning: false)
        XCTAssertEqual(state.rows, [.known(known), .discovered(found)])
        XCTAssertNil(state.emptyHint)
    }
}
