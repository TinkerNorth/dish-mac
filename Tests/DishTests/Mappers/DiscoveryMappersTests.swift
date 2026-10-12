// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishEngine
import XCTest
@testable import Dish

final class DiscoveryMappersTests: XCTestCase {

    func testEverySourceHasItsWord() {
        XCTAssertEqual(discoverySourceText(.broadcast), "UDP broadcast")
        XCTAssertEqual(discoverySourceText(.mdns), "mDNS")
        XCTAssertEqual(discoverySourceText(.both), "mDNS + broadcast")
        XCTAssertEqual(discoverySourceText(.manual), "added by address")
    }

    func testTitlePrefersTheNameAndFallsBackToTheAddress() {
        XCTAssertEqual(serverTitle(DiscoveredServer(name: "Desk", ip: "10.0.0.5")), "Desk")
        XCTAssertEqual(serverTitle(DiscoveredServer(name: "", ip: "10.0.0.5")), "10.0.0.5")
    }

    func testDetailIsAddressAndPort() {
        XCTAssertEqual(serverDetail(DiscoveredServer(ip: "10.0.0.5", udpPort: 9876)), "10.0.0.5 • UDP 9876")
    }

    func testDiscoveredStatusNamesThePath() {
        XCTAssertEqual(discoveredStatusText(DiscoveredServer(ip: "10.0.0.5", source: .mdns)), "Found · mDNS")
    }

    func testRowsListKnownFirstThenOnlyNewDiscoveries() {
        let known = [ConnectionSummary(id: "mid:abc", label: "Desk", detail: "", live: .saved, boundSlotId: nil)]
        let alreadyKnown = DiscoveredServer(name: "Desk", ip: "10.0.0.5", machineId: "abc")
        let fresh = DiscoveredServer(name: "Sofa", ip: "10.0.0.6", machineId: "def")
        let rows = connectionRows(known: known, discovered: [alreadyKnown, fresh])
        XCTAssertEqual(rows, [.known(known[0]), .discovered(fresh)])
        XCTAssertEqual(rows.map(\.key), ["mid:abc", "mid:def"])
    }

    func testNoRowsWhenNothingIsKnownOrHeard() {
        XCTAssertEqual(connectionRows(known: [], discovered: []), [])
    }
}
