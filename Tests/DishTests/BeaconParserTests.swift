// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import XCTest
@testable import Dish

final class BeaconParserTests: XCTestCase {

    func testParsesFullyPopulatedBeacon() {
        let json = """
        {
            "service": "satellite",
            "name": "LivingRoomPC",
            "udpPort": 9876,
            "pairPort": 9878,
            "httpPort": 9877
        }
        """
        let server = LANDiscovery.parseBeacon(json: json, ip: "192.168.1.42")
        XCTAssertNotNil(server)
        XCTAssertEqual(server?.name, "LivingRoomPC")
        XCTAssertEqual(server?.ip, "192.168.1.42")
        XCTAssertEqual(server?.udpPort, 9876)
        XCTAssertEqual(server?.pairPort, 9878)
        XCTAssertEqual(server?.httpPort, 9877)
    }

    func testOverridesJsonIpWithObservedIp() {
        // The JSON ip field (if any) is untrusted; the caller always overlays
        // the address the packet was observed from so spoofed beacons can't
        // misroute the session.
        let json = """
        {"service":"satellite","name":"x","ip":"10.0.0.1","udpPort":9876,"pairPort":9878,"httpPort":9877}
        """
        let server = LANDiscovery.parseBeacon(json: json, ip: "192.168.1.7")
        XCTAssertEqual(server?.ip, "192.168.1.7")
    }

    func testRejectsBeaconWithEmptyName() {
        let json = """
        {"service":"satellite","name":"","udpPort":9876,"pairPort":9878,"httpPort":9877}
        """
        XCTAssertNil(LANDiscovery.parseBeacon(json: json, ip: "1.2.3.4"))
    }

    func testRejectsMalformedJson() {
        XCTAssertNil(LANDiscovery.parseBeacon(json: "not-json", ip: "1.2.3.4"))
        XCTAssertNil(LANDiscovery.parseBeacon(json: "{\"name\":", ip: "1.2.3.4"))
    }

    func testParsesMachineIdFromBeacon() {
        // Protocol-1 beacons carry the stable machineId (see
        // satellite/src/net/discovery.cpp buildDiscoveryBeacon) — the identity
        // remembered satellites are keyed on.
        let json = """
        {"service":"satellite","name":"Basement","udpPort":9876,"pairPort":9443,"httpPort":9443,"machineId":"m-42"}
        """
        let server = LANDiscovery.parseBeacon(json: json, ip: "10.1.1.1")
        XCTAssertEqual(server?.machineId, "m-42")
        XCTAssertEqual(server?.id, "mid:m-42")
    }

    func testToleratesUnknownFields() {
        let json = """
        {
            "service": "satellite",
            "name": "Extra",
            "udpPort": 9876,
            "pairPort": 9878,
            "httpPort": 9877,
            "version": "0.9.1",
            "futureField": { "nested": true }
        }
        """
        let server = LANDiscovery.parseBeacon(json: json, ip: "10.0.0.5")
        XCTAssertEqual(server?.name, "Extra")
    }
}
