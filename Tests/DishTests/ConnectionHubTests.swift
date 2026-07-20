// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// ConnectionHub summary/binding invariants: the pool sink rebuilds from the
// EMITTED pool (a forgotten resting satellite must disappear synchronously —
// no later emission exists to self-correct on), and `bind` evicts the prior
// owner on BOTH sides so no connection is left believing it owns a slot the
// binding table gave away.

import XCTest
@testable import Dish

@MainActor
final class ConnectionHubTests: XCTestCase {

    private var defaults: UserDefaults!
    private var defaultsName: String!
    private var store: ConnectionStore!
    private var wifi: WifiConnectionManager!
    private var hub: ConnectionHub!

    override func setUp() {
        super.setUp()
        defaultsName = "dish.test.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsName)
        store = ConnectionStore(defaults: defaults, keyStore: InMemoryKeyStore())
        wifi = WifiConnectionManager(store: store)
        hub = ConnectionHub(wifi: wifi, store: store)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: defaultsName)
        super.tearDown()
    }

    private func server(_ suffix: String) -> DiscoveredServer {
        DiscoveredServer(
            name: "Sat-\(suffix)",
            ip: "192.0.2.\(suffix)",
            udpPort: 9876,
            machineId: "sat-\(suffix)"
        )
    }

    // MARK: - Forget removes the row synchronously (emitted-pool rebuild)

    func testForgetIdleRememberedSatelliteRemovesRowSynchronously() {
        let sat = server("10")
        store.remember(sat)
        wifi.register(WifiConnection(id: sat.id, server: sat, tickIntervalNs: .max))
        XCTAssertEqual(hub.connections.map(\.id), [sat.id])

        wifi.forget(id: sat.id)

        // A resting (idle, non-stale) row produces NO later hub-visible
        // emission after forget — the pool change itself must remove it.
        XCTAssertTrue(
            hub.connections.isEmpty,
            "forgotten satellite must not linger as a ghost Offline row"
        )
    }

    func testForgetOneOfTwoSatellitesKeepsTheOther() {
        let alpha = server("11")
        let beta = server("12")
        store.remember(alpha)
        store.remember(beta)
        wifi.register(WifiConnection(id: alpha.id, server: alpha, tickIntervalNs: .max))
        wifi.register(WifiConnection(id: beta.id, server: beta, tickIntervalNs: .max))
        XCTAssertEqual(Set(hub.connections.map(\.id)), [alpha.id, beta.id])

        wifi.forget(id: alpha.id)

        XCTAssertEqual(hub.connections.map(\.id), [beta.id])
    }

    // MARK: - bind evicts BOTH sides

    func testBindEvictsConnectionsPriorSlot() {
        let sat = server("20")
        let conn = WifiConnection(id: sat.id, server: sat, tickIntervalNs: .max)
        wifi.register(conn)

        hub.bind(slotId: "slot-a", connectionId: sat.id, hasMotion: false, hasLight: false)
        hub.bind(slotId: "slot-b", connectionId: sat.id, hasMotion: false, hasLight: false)

        XCTAssertEqual(hub.bindings, ["slot-b": sat.id])
        XCTAssertEqual(conn.boundSlotId, "slot-b")
    }

    func testBindEvictsSlotsPriorConnection() {
        let alpha = server("21")
        let beta = server("22")
        let connAlpha = WifiConnection(id: alpha.id, server: alpha, tickIntervalNs: .max)
        let connBeta = WifiConnection(id: beta.id, server: beta, tickIntervalNs: .max)
        wifi.register(connAlpha)
        wifi.register(connBeta)

        hub.bind(slotId: "slot-a", connectionId: alpha.id, hasMotion: false, hasLight: false)
        XCTAssertEqual(connAlpha.boundSlotId, "slot-a")

        // Rebinding the SLOT to another satellite must detach the first
        // connection too — otherwise it keeps advertising a desired
        // descriptor for a slot it no longer owns (zombie pad).
        hub.bind(slotId: "slot-a", connectionId: beta.id, hasMotion: false, hasLight: false)

        XCTAssertEqual(hub.bindings, ["slot-a": beta.id])
        XCTAssertEqual(connBeta.boundSlotId, "slot-a")
        XCTAssertNil(
            connAlpha.boundSlotId,
            "the slot's prior connection must be detached on rebind"
        )
    }
}
