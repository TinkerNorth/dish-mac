// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// ConnectionHub summary/binding invariants: the pool sink rebuilds from the
// EMITTED pool (a forgotten resting satellite must disappear synchronously —
// no later emission exists to self-correct on), a satellite carries up to
// four pads on the lowest free controller indices, and a slot bound
// elsewhere lets its prior satellite go so no connection is left believing
// it owns a pad the binding table gave away.

import Combine
import XCTest
@testable import DishEngine

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

    // MARK: - A row is data

    func testARememberedSatellitesRowCarriesItsNameAddressAndPortUnworded() {
        let sat = server("13")
        store.remember(sat)
        wifi.register(WifiConnection(id: sat.id, server: sat, tickIntervalNs: .max))
        let row = hub.connections.first
        XCTAssertEqual(row?.name, "Sat-13")
        XCTAssertEqual(row?.address, "192.0.2.13")
        XCTAssertEqual(row?.udpPort, 9876)
    }

    func testRowsAreOrderedByNameWithAnUnnamedSatelliteByItsAddress() {
        let named = server("14")
        let unnamed = DiscoveredServer(name: "", ip: "192.0.2.1", udpPort: 9876, machineId: "sat-unnamed")
        store.remember(named)
        store.remember(unnamed)
        wifi.register(WifiConnection(id: named.id, server: named, tickIntervalNs: .max))
        wifi.register(WifiConnection(id: unnamed.id, server: unnamed, tickIntervalNs: .max))
        XCTAssertEqual(hub.connections.map(\.recordName), ["192.0.2.1", "Sat-14"])
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

    // MARK: - Up to four pads per satellite

    @discardableResult
    private func pooled(_ sat: DiscoveredServer) -> WifiConnection {
        let conn = WifiConnection(id: sat.id, server: sat, tickIntervalNs: .max)
        wifi.register(conn)
        return conn
    }

    @discardableResult
    private func bind(_ slotId: String, to sat: DiscoveredServer) -> Bool {
        hub.bind(slotId: slotId, connectionId: sat.id, capabilities: .none, family: .other)
    }

    func testASatelliteCarriesFourPadsOnTheLowestFreeIndicesAndRefusesAFifth() {
        let sat = server("20")
        let conn = pooled(sat)
        for slotId in ["a", "b", "c", "d"] {
            XCTAssertTrue(bind(slotId, to: sat))
        }
        XCTAssertEqual(["a", "b", "c", "d"].map(conn.controllerIndex(of:)), [0, 1, 2, 3])
        XCTAssertEqual(hub.summary(sat.id)?.boundSlotIds, ["a", "b", "c", "d"])
        XCTAssertEqual(hub.summary(sat.id)?.hasRoomForAnotherSlot, false)

        XCTAssertFalse(bind("e", to: sat), "a fifth pad is refused")
        XCTAssertNil(hub.bindings["e"])
        XCTAssertNil(conn.controllerIndex(of: "e"))
        XCTAssertEqual(conn.boundSlotIds.count, 4, "nobody was evicted")
    }

    func testUnbindingFreesTheIndexAndTheNextPadTakesTheLowestFreeOne() {
        let sat = server("21")
        let conn = pooled(sat)
        for slotId in ["a", "b", "c"] {
            bind(slotId, to: sat)
        }
        hub.unbind(slotId: "b")
        XCTAssertNil(conn.controllerIndex(of: "b"))
        XCTAssertEqual(conn.controllerIndex(of: "c"), 2, "a bound pad keeps its index")
        bind("d", to: sat)
        XCTAssertEqual(conn.controllerIndex(of: "d"), 1, "the freed index is reused first")
        XCTAssertEqual(hub.summary(sat.id)?.boundSlotIds, ["a", "d", "c"], "the row lists the pads in index order")
    }

    func testRebindingAPadItsSatelliteCarriesKeepsItsIndex() {
        let sat = server("22")
        let conn = pooled(sat)
        bind("a", to: sat)
        bind("b", to: sat)
        XCTAssertTrue(bind("b", to: sat))
        XCTAssertEqual(conn.controllerIndex(of: "b"), 1)
        XCTAssertEqual(conn.boundSlotIds, ["a", "b"])
    }

    func testAFullSatelliteStillTakesBackAPadItCarries() {
        let sat = server("23")
        pooled(sat)
        for slotId in ["a", "b", "c", "d"] {
            bind(slotId, to: sat)
        }
        XCTAssertTrue(bind("d", to: sat), "the cap counts the other pads")
    }

    func testBindingASlotElsewhereLetsItsPriorSatelliteGo() {
        let alpha = server("24")
        let beta = server("25")
        let connAlpha = pooled(alpha)
        let connBeta = pooled(beta)
        bind("a", to: alpha)
        bind("b", to: alpha)

        // Rebinding the SLOT to another satellite must detach it from the
        // first one too, or the first keeps advertising a descriptor for a
        // pad it no longer owns (zombie pad).
        bind("a", to: beta)

        XCTAssertEqual(hub.bindings, ["a": beta.id, "b": alpha.id])
        XCTAssertEqual(connBeta.boundSlotIds, ["a"])
        XCTAssertEqual(connAlpha.boundSlotIds, ["b"], "the slot's prior satellite let go of that pad alone")
    }

    func testThePadsRouteIsKnownTheMomentTheBindingPublishes() {
        let sat = server("26")
        let conn = pooled(sat)
        var indexAtPublish: Int?
        let watch = hub.$bindings.dropFirst().sink { _ in indexAtPublish = conn.controllerIndex(of: "a") }
        bind("a", to: sat)
        watch.cancel()
        XCTAssertEqual(indexAtPublish, 0, "the satellite took the pad before the table published")
    }

    // MARK: - Bound-slot type defaults to the catalog's first offered type

    private func catalog(firstId: Int, slug: String) throws -> CatalogDTO {
        let json = """
        {"controllerTypes":[{"id":\(firstId),"slug":"\(slug)",
          "features":{"rumble":{"supported":true}}}]}
        """
        return try JSONDecoder().decode(CatalogDTO.self, from: Data(json.utf8))
    }

    func testBindDefaultsToCatalogFirstType() throws {
        let sat = server("30")
        let conn = WifiConnection(id: sat.id, server: sat, tickIntervalNs: .max)
        wifi.register(conn)
        try wifi.cacheCatalog(catalog(firstId: 1, slug: "ds4"), for: sat.id)

        hub.bind(slotId: "slot-a", connectionId: sat.id, capabilities: .none, family: .other)

        // A ds4-first satellite (e.g. a Mac host) → the bound descriptor
        // carries type 1, not the legacy hardcoded 0.
        XCTAssertEqual(conn.descriptor(for: "slot-a")?.type, 1)
    }

    func testBindHonoursCatalogFirstTypeWhenXbox() throws {
        let sat = server("31")
        let conn = WifiConnection(id: sat.id, server: sat, tickIntervalNs: .max)
        wifi.register(conn)
        try wifi.cacheCatalog(catalog(firstId: 0, slug: "xbox360"), for: sat.id)

        hub.bind(slotId: "slot-a", connectionId: sat.id, capabilities: .none, family: .other)

        XCTAssertEqual(conn.descriptor(for: "slot-a")?.type, 0)
    }

    func testBindFallsBackToTypeZeroWithoutCatalog() {
        let sat = server("32")
        let conn = WifiConnection(id: sat.id, server: sat, tickIntervalNs: .max)
        wifi.register(conn)

        // No catalog fetched (older / unreachable satellite): the prior
        // behavior — type 0 — stands so nothing regresses.
        hub.bind(slotId: "slot-a", connectionId: sat.id, capabilities: .none, family: .other)

        XCTAssertEqual(conn.descriptor(for: "slot-a")?.type, 0)
    }

    func testEmptyCatalogIsIgnoredAndFallsBack() {
        let sat = server("33")
        let conn = WifiConnection(id: sat.id, server: sat, tickIntervalNs: .max)
        wifi.register(conn)
        wifi.cacheCatalog(CatalogDTO(), for: sat.id) // empty → not cached

        hub.bind(slotId: "slot-a", connectionId: sat.id, capabilities: .none, family: .other)

        XCTAssertEqual(conn.descriptor(for: "slot-a")?.type, 0)
    }
}
