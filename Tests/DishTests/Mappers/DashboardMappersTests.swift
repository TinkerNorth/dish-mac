// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishEngine
import XCTest
@testable import Dish

final class DashboardMappersTests: XCTestCase {

    private func summary(_ id: String, _ live: LinkState) -> ConnectionSummary {
        ConnectionSummary(id: id, name: "Server \(id)", live: live, boundSlotId: nil)
    }

    func testNothingPairedYet() {
        XCTAssertEqual(dashboardStatusText([]), "No connections yet")
        XCTAssertEqual(dashboardSummaryText([]), "Plug in a controller and pair a Satellite to get started")
    }

    func testPairedButNoneLiveCountsThePaired() {
        let connections = [summary("a", .saved), summary("b", .ready)]
        XCTAssertEqual(dashboardStatusText(connections), "2 paired")
        XCTAssertEqual(dashboardSummaryText(connections), "2 paired")
    }

    func testOneLiveServerShowsItsName() {
        let connections = [summary("a", .saved), summary("b", .connected)]
        XCTAssertEqual(dashboardStatusText(connections), "Server b")
        XCTAssertEqual(dashboardSummaryText(connections), "1 of 2 online")
    }

    func testSeveralLiveServersShowTheCount() {
        let connections = [summary("a", .connected), summary("b", .connected), summary("c", .unstable)]
        XCTAssertEqual(dashboardStatusText(connections), "2 active connections")
        XCTAssertEqual(dashboardSummaryText(connections), "2 of 3 online")
    }

    func testAnUnsteadySessionDoesNotCountAsLive() {
        XCTAssertEqual(liveConnections([summary("a", .unstable), summary("b", .connecting)]).count, 0)
    }

    func testTheAccentTurnsGreenWithTheFirstLiveServer() {
        XCTAssertEqual(dashboardAccent(liveCount: 0), DishTheme.muted)
        XCTAssertEqual(dashboardAccent(liveCount: 1), DishTheme.success)
        XCTAssertEqual(dashboardIconState(liveCount: 0), .default)
        XCTAssertEqual(dashboardIconState(liveCount: 2), .connected)
    }
}
