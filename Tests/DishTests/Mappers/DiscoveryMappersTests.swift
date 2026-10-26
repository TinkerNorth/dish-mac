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

    func testTheFoundRowSaysWhereTheServerAnsweredAndHowItWasHeard() {
        XCTAssertEqual(foundServerDetail(DiscoveredServer(ip: "10.0.0.5", source: .mdns)), "10.0.0.5 · mDNS")
    }

    func testAServerAPairedCardShowsIsNotFoundAgain() {
        let known = [ConnectionSummary(id: "mid:abc", name: "Desk", live: .saved, boundSlotId: nil)]
        let alreadyKnown = DiscoveredServer(name: "Desk", ip: "10.0.0.5", machineId: "abc")
        let fresh = DiscoveredServer(name: "Sofa", ip: "10.0.0.6", machineId: "def")
        XCTAssertEqual(foundServers([alreadyKnown, fresh], known: known), [fresh])
        XCTAssertEqual(foundServers([], known: []), [])
    }
}
