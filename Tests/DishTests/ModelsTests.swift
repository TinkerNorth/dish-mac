// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import XCTest
@testable import Dish

final class ModelsTests: XCTestCase {

    func testDiscoveredServerIdEncodesIpAndUdpPort() {
        let s = DiscoveredServer(
            name: "foo",
            ip: "10.0.0.1",
            udpPort: 9876,
            pairPort: 9878,
            httpPort: 9877
        )
        XCTAssertEqual(s.id, "wifi:10.0.0.1:9876")
    }

    func testRememberedWifiRoundTripsToDiscovered() {
        let r = RememberedWifi(
            id: "wifi:1.2.3.4:9000",
            name: "HomePC",
            ip: "1.2.3.4",
            udpPort: 9000,
            pairPort: 9001,
            httpPort: 9002
        )
        let d = r.toDiscovered()
        XCTAssertEqual(d.name, "HomePC")
        XCTAssertEqual(d.ip, "1.2.3.4")
        XCTAssertEqual(d.udpPort, 9000)
        XCTAssertEqual(d.pairPort, 9001)
        XCTAssertEqual(d.httpPort, 9002)
    }

    func testRememberedWifiCodableRoundTrip() throws {
        let original = RememberedWifi(
            id: "wifi:192.168.1.5:9876",
            name: "Den",
            ip: "192.168.1.5",
            udpPort: 9876,
            pairPort: 9878,
            httpPort: 9877
        )
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(RememberedWifi.self, from: encoded)
        XCTAssertEqual(decoded, original)
    }

    func testVirtualSlotIdConstantIsStable() {
        // The server keys slot bindings on this id — any rename is a wire-
        // breaking change vs. the Android client.
        XCTAssertEqual(VIRTUAL_SLOT_ID, "virtual")
    }
}
