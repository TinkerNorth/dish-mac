// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import XCTest
@testable import Dish

final class ModelsTests: XCTestCase {

    // MARK: - Manual add-by-address (the discovery-denied escape hatch)

    func testManualEntryParsesIPv4WithDefaultAndExplicitPort() throws {
        let plain = try XCTUnwrap(DiscoveredServer.manual(from: " 192.168.1.50 "))
        XCTAssertEqual(plain.ip, "192.168.1.50")
        XCTAssertEqual(plain.udpPort, 9876)
        XCTAssertEqual(plain.id, "wifi:192.168.1.50:9876", "manual entries ride the legacy identity")
        XCTAssertEqual(plain.source, .manual)

        let ported = try XCTUnwrap(DiscoveredServer.manual(from: "10.0.0.9:9999"))
        XCTAssertEqual(ported.udpPort, 9999)
        XCTAssertEqual(ported.id, "wifi:10.0.0.9:9999")
    }

    func testManualEntryRejectsNonIPv4AndBadPorts() {
        XCTAssertNil(DiscoveredServer.manual(from: ""))
        XCTAssertNil(DiscoveredServer.manual(from: "mac-mini.local"), "the UDP plane dials IPv4 literals only")
        XCTAssertNil(DiscoveredServer.manual(from: "999.1.1.1"))
        XCTAssertNil(DiscoveredServer.manual(from: "192.168.1.50:0"))
        XCTAssertNil(DiscoveredServer.manual(from: "192.168.1.50:70000"))
        XCTAssertNil(DiscoveredServer.manual(from: "192.168.1.50:abc"))
        XCTAssertNil(DiscoveredServer.manual(from: "1.2.3.4:9:9"))
    }

    func testDiscoveredServerIdEncodesIpAndUdpPortWhenNoMachineId() {
        let server = DiscoveredServer(
            name: "foo",
            ip: "10.0.0.1",
            udpPort: 9876,
            pairPort: 9878,
            httpPort: 9877
        )
        XCTAssertEqual(server.id, "wifi:10.0.0.1:9876")
    }

    func testDiscoveredServerIdPrefersMachineId() {
        // Contract §Identity: clients MUST key remembered satellites on
        // machineId alone, never on ip/port — the id survives a DHCP move.
        let server = DiscoveredServer(
            name: "foo",
            ip: "10.0.0.1",
            udpPort: 9876,
            machineId: "m-abc123"
        )
        XCTAssertEqual(server.id, "mid:m-abc123")
        var moved = server
        moved.ip = "10.0.0.99"
        XCTAssertEqual(moved.id, server.id)
    }

    func testDiscoveredServerDecodesMachineIdLeniently() throws {
        let withId = try JSONDecoder().decode(
            DiscoveredServer.self,
            from: Data(#"{"name":"x","machineId":"m-1"}"#.utf8)
        )
        XCTAssertEqual(withId.machineId, "m-1")
        XCTAssertEqual(withId.id, "mid:m-1")
        // Pre-protocol-1 beacons omit machineId — the decode must not fail
        // and the id must fall back to the legacy endpoint form.
        let without = try JSONDecoder().decode(
            DiscoveredServer.self,
            from: Data(#"{"name":"x","udpPort":9876}"#.utf8)
        )
        XCTAssertEqual(without.machineId, "")
        XCTAssertEqual(without.id, "wifi::9876")
    }

    func testRememberedWifiRoundTripsToDiscovered() {
        let remembered = RememberedWifi(
            id: "wifi:1.2.3.4:9000",
            name: "HomePC",
            ip: "1.2.3.4",
            udpPort: 9000,
            pairPort: 9001,
            httpPort: 9002
        )
        let discovered = remembered.toDiscovered()
        XCTAssertEqual(discovered.name, "HomePC")
        XCTAssertEqual(discovered.ip, "1.2.3.4")
        XCTAssertEqual(discovered.udpPort, 9000)
        XCTAssertEqual(discovered.pairPort, 9001)
        XCTAssertEqual(discovered.httpPort, 9002)
    }

    func testRememberedWifiCodableRoundTrip() throws {
        let original = RememberedWifi(
            id: "mid:m-7",
            name: "Den",
            ip: "192.168.1.5",
            udpPort: 9876,
            pairPort: 9878,
            httpPort: 9877,
            machineId: "m-7"
        )
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(RememberedWifi.self, from: encoded)
        XCTAssertEqual(decoded, original)
    }

    func testRememberedWifiDecodesLegacyRowWithoutMachineId() throws {
        // Rows persisted before protocol-1 have no machineId key. They must
        // still load (empty machineId) — a strict decoder would silently
        // forget every saved satellite on app upgrade.
        let legacy = Data(
            #"{"id":"wifi:1.2.3.4:9876","name":"Old","ip":"1.2.3.4","udpPort":9876,"pairPort":9878,"httpPort":9877}"#
                .utf8
        )
        let decoded = try JSONDecoder().decode(RememberedWifi.self, from: legacy)
        XCTAssertEqual(decoded.id, "wifi:1.2.3.4:9876")
        XCTAssertEqual(decoded.machineId, "")
        XCTAssertEqual(decoded.toDiscovered().id, "wifi:1.2.3.4:9876")
    }

    func testRememberedWifiToDiscoveredCarriesMachineId() {
        let remembered = RememberedWifi(
            id: "mid:m-9",
            name: "Attic",
            ip: "1.2.3.4",
            udpPort: 9876,
            pairPort: 9443,
            httpPort: 9443,
            machineId: "m-9"
        )
        XCTAssertEqual(remembered.toDiscovered().machineId, "m-9")
        XCTAssertEqual(remembered.toDiscovered().id, "mid:m-9")
    }

    func testPairResponseDecodesProtocol1Fields() throws {
        let pending = try JSONDecoder().decode(
            PairResponse.self,
            from: Data(#"{"ok":false,"pending":true,"message":"awaiting approval"}"#.utf8)
        )
        XCTAssertFalse(pending.ok)
        XCTAssertTrue(pending.pending)
        XCTAssertEqual(pending.protocolVersion, 1)

        let versioned = try JSONDecoder().decode(
            PairResponse.self,
            from: Data(#"{"ok":true,"sharedKey":"ab","protocolVersion":2}"#.utf8)
        )
        XCTAssertEqual(versioned.protocolVersion, 2)
        // Client-side fields never come from the wire.
        XCTAssertFalse(versioned.reachable)
        XCTAssertEqual(versioned.httpStatus, 0)
    }
}
