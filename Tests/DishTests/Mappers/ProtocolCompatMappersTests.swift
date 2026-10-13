// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import XCTest
@testable import Dish

final class ProtocolCompatMappersTests: XCTestCase {

    func testACurrentOrUnnegotiatedSatelliteWearsNoChip() {
        XCTAssertNil(protocolCompatText(.unknown))
        XCTAssertNil(protocolCompatText(.current))
    }

    func testTheSoftHintIsAmberAndTheHardWordsAreRed() {
        XCTAssertEqual(protocolCompatText(.satelliteUpdateAvailable), "Satellite update recommended")
        XCTAssertEqual(protocolCompatColor(.satelliteUpdateAvailable), DishTheme.warning)
        XCTAssertEqual(protocolCompatText(.satelliteUpdateRequired), "Satellite update required")
        XCTAssertEqual(protocolCompatColor(.satelliteUpdateRequired), DishTheme.error)
        XCTAssertEqual(protocolCompatText(.dishUpdateRequired), "Dish update required")
        XCTAssertEqual(protocolCompatColor(.dishUpdateRequired), DishTheme.error)
    }

    func testTheRestingStatesStayMuted() {
        XCTAssertEqual(protocolCompatColor(.unknown), DishTheme.muted)
        XCTAssertEqual(protocolCompatColor(.current), DishTheme.muted)
    }
}
