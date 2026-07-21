// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// G11: machineId identity keying, legacy-ghost collapse, DHCP re-home and
// pin migration — the dish-linux ConnectionStore semantics, rule for rule.

import XCTest
@testable import Dish

final class ConnectionStoreIdentityTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!
    private var keyStore: InMemoryKeyStore!
    private var store: ConnectionStore!

    override func setUp() {
        super.setUp()
        suiteName = "dish.test.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        keyStore = InMemoryKeyStore()
        store = ConnectionStore(defaults: defaults, keyStore: keyStore)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func server(
        name: String = "Box",
        ip: String = "10.0.0.1",
        udpPort: Int = 9876,
        machineId: String = ""
    ) -> DiscoveredServer {
        DiscoveredServer(
            name: name,
            ip: ip,
            udpPort: udpPort,
            pairPort: 9443,
            httpPort: 9443,
            machineId: machineId
        )
    }

    // MARK: - remember() identity rules

    func testRemembersUnderMachineIdKey() {
        store.remember(server(machineId: "m-1"))
        let rows = store.remembered()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].id, "mid:m-1")
        XCTAssertEqual(rows[0].machineId, "m-1")
    }

    func testReRememberSameIdReplacesRow() {
        store.remember(server(name: "Old", machineId: "m-1"))
        store.remember(server(name: "New", ip: "10.0.0.2", machineId: "m-1"))
        let rows = store.remembered()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].name, "New")
        XCTAssertEqual(rows[0].ip, "10.0.0.2")
    }

    func testLegacyGhostCollapsesWhenBoxGainsStableId() {
        // Pre-protocol-1: remembered by endpoint, key stored under the wifi id.
        let legacy = server()
        store.remember(legacy)
        store.setSharedKey("aa11", for: legacy.id)

        // Same box, now advertising a machineId.
        store.remember(server(machineId: "m-1"))

        let rows = store.remembered()
        XCTAssertEqual(rows.count, 1, "the legacy ghost row must collapse")
        XCTAssertEqual(rows[0].id, "mid:m-1")
        // The pairing key carried forward to the stable id; the ghost's key is gone.
        XCTAssertEqual(store.sharedKey(for: "mid:m-1"), "aa11")
        XCTAssertNil(store.sharedKey(for: legacy.id))
    }

    func testGhostCollapseNeverOverwritesStableRowsOwnKey() {
        let legacy = server()
        store.remember(legacy)
        store.setSharedKey("ghost-key", for: legacy.id)
        store.setSharedKey("stable-key", for: "mid:m-1")

        store.remember(server(machineId: "m-1"))

        XCTAssertEqual(store.sharedKey(for: "mid:m-1"), "stable-key")
        XCTAssertNil(store.sharedKey(for: legacy.id))
    }

    func testMachineIdlessResultOnlyRefreshesKnownStableRow() {
        store.remember(server(name: "Stable", machineId: "m-1"))

        // The same box heard over the legacy beacon (no machineId): must NOT
        // mint a wifi: ghost beside the stable row, only refresh name/ports.
        var beacon = server(name: "Renamed")
        beacon.pairPort = 9444
        beacon.httpPort = 9444
        store.remember(beacon)

        let rows = store.remembered()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].id, "mid:m-1")
        XCTAssertEqual(rows[0].name, "Renamed")
        XCTAssertEqual(rows[0].pairPort, 9444)
        XCTAssertEqual(rows[0].httpPort, 9444)
    }

    func testMachineIdlessResultAtUnknownAddressMintsLegacyRow() {
        store.remember(server(ip: "10.9.9.9"))
        let rows = store.remembered()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].id, "wifi:10.9.9.9:9876")
    }

    // MARK: - Pin migration on address change

    func testPinFollowsBoxAcrossAddressChange() {
        store.remember(server(ip: "10.0.0.1", machineId: "m-1"))
        store.setCertPin(host: "10.0.0.1", fingerprintHex: "aaaa")

        // DHCP moved the box; same machineId, new IP.
        store.remember(server(ip: "10.0.0.9", machineId: "m-1"))

        XCTAssertEqual(store.certPin(host: "10.0.0.9"), "aaaa")
        XCTAssertNil(store.certPin(host: "10.0.0.1"), "old-address pin is always dropped")
    }

    func testExistingPinAtNewAddressIsNotOverwritten() {
        store.remember(server(ip: "10.0.0.1", machineId: "m-1"))
        store.setCertPin(host: "10.0.0.1", fingerprintHex: "aaaa")
        store.setCertPin(host: "10.0.0.9", fingerprintHex: "bbbb")

        store.remember(server(ip: "10.0.0.9", machineId: "m-1"))

        XCTAssertEqual(store.certPin(host: "10.0.0.9"), "bbbb")
        XCTAssertNil(store.certPin(host: "10.0.0.1"))
    }

    // MARK: - refreshFromDiscovery (DHCP re-home)

    func testRefreshFromDiscoveryRehomesRememberedBox() {
        store.remember(server(ip: "10.0.0.1", machineId: "m-1"))
        store.setCertPin(host: "10.0.0.1", fingerprintHex: "aaaa")

        store.refreshFromDiscovery([server(ip: "10.0.0.77", machineId: "m-1")])

        let rows = store.remembered()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].ip, "10.0.0.77")
        XCTAssertEqual(store.certPin(host: "10.0.0.77"), "aaaa")
    }

    func testRefreshFromDiscoveryUpgradesLegacyRow() {
        let legacy = server(ip: "10.0.0.1")
        store.remember(legacy)
        store.setSharedKey("aa11", for: legacy.id)

        store.refreshFromDiscovery([server(ip: "10.0.0.1", machineId: "m-1")])

        let rows = store.remembered()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].id, "mid:m-1")
        XCTAssertEqual(store.sharedKey(for: "mid:m-1"), "aa11")
    }

    func testRefreshFromDiscoveryNeverAddsUnknownSatellite() {
        store.refreshFromDiscovery([server(ip: "10.0.0.5", machineId: "m-new")])
        XCTAssertTrue(store.remembered().isEmpty)
    }

    func testRefreshFromDiscoveryIgnoresMachineIdlessResults() {
        store.remember(server(ip: "10.0.0.1", machineId: "m-1"))
        // A beaconed (id-less) result at a NEW address must not re-point the row.
        store.refreshFromDiscovery([server(ip: "10.0.0.99")])
        XCTAssertEqual(store.remembered()[0].ip, "10.0.0.1")
    }

    // MARK: - forget / forgetKey

    func testForgetDropsRowKeyAndPin() {
        let box = server(ip: "10.0.0.1", machineId: "m-1")
        store.remember(box)
        store.setSharedKey("aa11", for: "mid:m-1")
        store.setCertPin(host: "10.0.0.1", fingerprintHex: "cccc")

        store.forget("mid:m-1")

        XCTAssertTrue(store.remembered().isEmpty)
        XCTAssertNil(store.sharedKey(for: "mid:m-1"))
        XCTAssertNil(store.certPin(host: "10.0.0.1"))
    }

    func testForgetKeyKeepsRowAndPin() {
        // Terminal 401 semantics: drop ONLY the key so the UI can park the
        // row on "Needs pairing" instead of deleting the satellite.
        store.remember(server(ip: "10.0.0.1", machineId: "m-1"))
        store.setSharedKey("aa11", for: "mid:m-1")
        store.setCertPin(host: "10.0.0.1", fingerprintHex: "cccc")

        store.forgetKey(for: "mid:m-1")

        XCTAssertEqual(store.remembered().count, 1)
        XCTAssertNil(store.sharedKey(for: "mid:m-1"))
        XCTAssertEqual(store.certPin(host: "10.0.0.1"), "cccc")
    }

    // MARK: - Pin store basics

    func testCertPinRoundTripAndClear() {
        XCTAssertNil(store.certPin(host: "10.1.1.1"))
        store.setCertPin(host: "10.1.1.1", fingerprintHex: "abcd")
        XCTAssertEqual(store.certPin(host: "10.1.1.1"), "abcd")
        store.forgetCertPin(host: "10.1.1.1")
        XCTAssertNil(store.certPin(host: "10.1.1.1"))
        // Writing an empty pin clears (nil stays the only never-pinned signal).
        store.setCertPin(host: "10.1.1.1", fingerprintHex: "abcd")
        store.setCertPin(host: "10.1.1.1", fingerprintHex: "")
        XCTAssertNil(store.certPin(host: "10.1.1.1"))
    }
}
