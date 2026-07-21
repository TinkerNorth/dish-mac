// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// Reconcile driver end-to-end (gap G9 policy side) against the W1-C
// FakeSatellite: the enriched ack's epoch/bitmap drift triggers the manager's
// GET, benign drift adopts the epoch without touching the session, real
// divergence (server-side unplug behind our back) re-PUTs the full desired
// state, and a terminal 401 on the reconcile GET funnels into the
// centralised terminal-auth handler. Bounded predicate waits only.

import Combine
import DishCore
import XCTest
@testable import Dish

@MainActor
final class ReconcileDriverLiveTests: XCTestCase {

    private var satellite: FakeSatellite!
    private var ports: FakeSatellite.Ports!
    private var defaults: UserDefaults!
    private var defaultsName: String!
    private var store: ConnectionStore!
    private var manager: WifiConnectionManager!
    private var events: [ConnectionEvent] = []
    private var bag = Set<AnyCancellable>()
    private static let keyHex = String(repeating: "1f", count: 32)

    override func setUpWithError() throws {
        try super.setUpWithError()
        satellite = try FakeSatellite()
        ports = try satellite.start()
        try satellite.requireHTTPSTransport()
        defaultsName = "dish.test.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsName)
        store = ConnectionStore(defaults: defaults, keyStore: InMemoryKeyStore())
        manager = WifiConnectionManager(store: store)
        events = []
        manager.events
            .sink { [weak self] event in self?.events.append(event) }
            .store(in: &bag)
        satellite.pairingKeyHex = Self.keyHex
        store.setSharedKey(Self.keyHex, for: server.id)
    }

    override func tearDown() {
        for id in manager.connections.keys {
            manager.disconnect(id: id)
        }
        satellite.stop()
        defaults.removePersistentDomain(forName: defaultsName)
        bag.removeAll()
        super.tearDown()
    }

    private var server: DiscoveredServer {
        DiscoveredServer(
            name: "Fake",
            ip: "127.0.0.1",
            udpPort: Int(ports.udp),
            pairPort: Int(ports.rest),
            httpPort: Int(ports.rest),
            machineId: satellite.machineId
        )
    }

    private func waitUntil(
        timeout: TimeInterval = 8,
        _ predicate: () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return predicate()
    }

    @discardableResult
    private func connectAndAwaitLive() async throws -> WifiConnection {
        manager.connect(to: server)
        let live = await waitUntil { self.manager.get(self.server.id)?.state == .live }
        XCTAssertTrue(live, "keyed connect must reach .live")
        return try XCTUnwrap(manager.get(server.id))
    }

    // MARK: - Benign drift: GET, adopt, keep the session

    func testBenignEpochDriftAdoptsEpochWithoutRePut() async throws {
        let conn = try await connectAndAwaitLive()
        XCTAssertTrue(satellite.awaitHeartbeats(atLeast: 1))
        XCTAssertEqual(satellite.sessionPuts.count, 1)
        XCTAssertTrue(satellite.reconcileGets.isEmpty, "no drift yet — no GET")

        // The ack (and the GET view) now report a bumped epoch while the
        // applied topology still matches what we want (nothing bound).
        satellite.ackEpochOverride = 42

        let got = await waitUntil { self.satellite.reconcileGets.count >= 1 }
        XCTAssertTrue(got, "epoch drift must trigger the reconcile GET")
        let adopted = await waitUntil { conn.lastAppliedEpoch == 42 }
        XCTAssertTrue(adopted, "benign drift adopts the server epoch")
        XCTAssertEqual(conn.state, .live, "the session is untouched")

        // The loop is closed: adopted epoch matches the ack, so no further
        // GETs fire (bounded negative-observation window ≥ 2 ticks) and the
        // session was never re-PUT.
        let secondGet = await waitUntil(timeout: 2.5) { self.satellite.reconcileGets.count >= 2 }
        XCTAssertFalse(secondGet, "single GET per drift — the adopt closes the loop")
        XCTAssertEqual(satellite.sessionPuts.count, 1, "benign drift never re-PUTs")
    }

    // MARK: - Real divergence: GET, mismatch, re-PUT full desired state

    func testServerSideUnplugDivergenceRePutsDesiredTopology() async throws {
        let conn = try await connectAndAwaitLive()
        XCTAssertTrue(satellite.awaitHeartbeats(atLeast: 1))

        // Bind a slot and let the live converge apply it server-side.
        conn.attachSlot("slot-a", controllerType: 0, hasMotion: false, hasLight: false)
        let applied = await waitUntil { self.satellite.appliedControllers.count == 1 }
        XCTAssertTrue(applied)
        XCTAssertEqual(satellite.sessionPuts.count, 1, "live attach rides the per-slot route")

        // The admin surface unplugs our controller behind our back (the
        // loopback-9877 analogue — client-authed routes reject foreign
        // deviceIds): the epoch bumps, the bitmap empties, and OUR desired
        // state no longer matches the applied view.
        satellite.adminUnplugController(ctrlIdx: 0)
        XCTAssertTrue(satellite.appliedControllers.isEmpty, "the server dropped the slot")

        // Drift → GET → applied ≠ desired → full re-PUT through the normal
        // open path; the slot comes back without any user action.
        let rePut = await waitUntil { self.satellite.sessionPuts.count >= 2 }
        XCTAssertTrue(rePut, "real divergence must re-PUT the desired topology")
        XCTAssertGreaterThanOrEqual(satellite.reconcileGets.count, 1, "the GET precedes the re-PUT")
        let healed = await waitUntil {
            self.satellite.appliedControllers.count == 1 && conn.state == .live
        }
        XCTAssertTrue(healed, "the desired slot is re-applied and the session is live again")
        XCTAssertEqual(conn.boundSlotId, "slot-a", "the local binding never wavered")
    }

    // MARK: - Terminal 401 on the reconcile GET (terminal-auth funnel)

    func testReconcileGetTerminal401FunnelsToTerminalAuthQuietly() async throws {
        let conn = try await connectAndAwaitLive()
        XCTAssertTrue(satellite.awaitHeartbeats(atLeast: 1))

        // Trust revoked server-side; the next authed call 401s. Force drift
        // so the reconcile GET is that call.
        satellite.forced401Code = "NOT_PAIRED"
        satellite.ackEpochOverride = 99

        let keyDropped = await waitUntil { self.store.sharedKey(for: self.server.id) == nil }
        XCTAssertTrue(keyDropped, "a terminal 401 on the reconcile GET drops the key")
        XCTAssertTrue(manager.staleSatelliteIds.contains(server.id), "row parks on Needs pairing")
        let reaped = await waitUntil(timeout: 4) { conn.state == .idle }
        XCTAssertTrue(reaped)
        XCTAssertNil(manager.retry[server.id], "terminal auth stops the retry curve")
        let quiet = !events.contains {
            if case let .error(message) = $0 { return message == WifiConnectionManager.repairNeededMessage }
            return false
        }
        XCTAssertTrue(quiet, "nobody asked for the reconcile — the funnel stays quiet")
    }

    // MARK: - Latency readout (gap G13, tick side)

    func testAliveTickPublishesRoundedLatencyReadout() async throws {
        let conn = try await connectAndAwaitLive()
        XCTAssertTrue(satellite.awaitHeartbeats(atLeast: 1))

        let published = await waitUntil { conn.latencySamples >= 1 && conn.latencyOneWayMs != nil }
        XCTAssertTrue(published, "the tick must surface the one-way latency readout")
        let value = try XCTUnwrap(conn.latencyOneWayMs)
        XCTAssertGreaterThanOrEqual(value, 0)
        XCTAssertLessThan(value, 2500)
        XCTAssertEqual((value * 10).rounded() / 10, value, "readout is rounded to 0.1 ms")
    }
}
