// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import XCTest
@testable import Dish

/// Tests for the Task 1.6 mDNS discovery surface: the `DiscoverySource`
/// labelling, the `source` field's exclusion from the wire format, and the
/// two-path discovery merge (`WifiConnectionManager.mergeDiscovered`).
final class MdnsDiscoveryTests: XCTestCase {

    // MARK: - DiscoverySource

    func testDiscoverySourceLabels() {
        XCTAssertEqual(DiscoverySource.broadcast.label, "UDP broadcast")
        XCTAssertEqual(DiscoverySource.mdns.label, "mDNS")
        XCTAssertEqual(DiscoverySource.both.label, "mDNS + broadcast")
    }

    // MARK: - DiscoveredServer.source vs the wire format

    func testDecodedBeaconDefaultsToBroadcastSource() throws {
        // The satellite beacon JSON has no `source` key — a decoded server
        // must fall back to `.broadcast`, matching the legacy path.
        let json = #"{"service":"satellite","name":"sat","udpPort":9876,"pairPort":9878,"httpPort":9877}"#
        let server = try JSONDecoder().decode(DiscoveredServer.self, from: Data(json.utf8))
        XCTAssertEqual(server.source, .broadcast)
        XCTAssertEqual(server.name, "sat")
        XCTAssertEqual(server.udpPort, 9876)
    }

    func testSourceIsNotEncodedToWire() throws {
        // `source` is excluded from CodingKeys — encoding then decoding must
        // drop it back to the default, so it never leaks onto the wire.
        let server = DiscoveredServer(name: "sat", ip: "10.0.0.5", source: .mdns)
        let data = try JSONEncoder().encode(server)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(json.contains("source"))
        let decoded = try JSONDecoder().decode(DiscoveredServer.self, from: data)
        XCTAssertEqual(decoded.source, .broadcast)
    }

    // MARK: - WifiConnectionManager.mergeDiscovered

    private func server(_ name: String, _ ip: String, udp: Int = 9876) -> DiscoveredServer {
        DiscoveredServer(name: name, ip: ip, udpPort: udp)
    }

    func testMergeTagsBroadcastOnlyServer() {
        let merged = WifiConnectionManager.mergeDiscovered(
            broadcast: [server("A", "10.0.0.1")], mdns: [])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.source, .broadcast)
    }

    func testMergeTagsMdnsOnlyServer() {
        let merged = WifiConnectionManager.mergeDiscovered(
            broadcast: [], mdns: [server("B", "10.0.0.2")])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.source, .mdns)
    }

    func testMergeTagsServerHeardOnBothPathsAsBoth() {
        // Same ip + udpPort → same stable id → one merged entry, tagged .both.
        let merged = WifiConnectionManager.mergeDiscovered(
            broadcast: [server("Sat", "10.0.0.9")],
            mdns: [server("Sat", "10.0.0.9")])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.source, .both)
    }

    func testMergeKeepsDistinctServersFromEachPath() {
        let merged = WifiConnectionManager.mergeDiscovered(
            broadcast: [server("Alpha", "10.0.0.1")],
            mdns: [server("Bravo", "10.0.0.2")])
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged.first { $0.name == "Alpha" }?.source, .broadcast)
        XCTAssertEqual(merged.first { $0.name == "Bravo" }?.source, .mdns)
    }

    func testMergeDistinguishesSamePairIpDifferentPort() {
        // Two satellites on one host (different udpPort) are distinct ids.
        let merged = WifiConnectionManager.mergeDiscovered(
            broadcast: [server("One", "10.0.0.1", udp: 9876)],
            mdns: [server("Two", "10.0.0.1", udp: 9900)])
        XCTAssertEqual(merged.count, 2)
    }

    func testMergeSortsByName() {
        let merged = WifiConnectionManager.mergeDiscovered(
            broadcast: [server("Zulu", "10.0.0.3"), server("Alpha", "10.0.0.1")],
            mdns: [server("Mike", "10.0.0.2")])
        XCTAssertEqual(merged.map(\.name), ["Alpha", "Mike", "Zulu"])
    }

    func testMergeEmptyInputsYieldEmptyResult() {
        XCTAssertTrue(WifiConnectionManager.mergeDiscovered(broadcast: [], mdns: []).isEmpty)
    }
}
