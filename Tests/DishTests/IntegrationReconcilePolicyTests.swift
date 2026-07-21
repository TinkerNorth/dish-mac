// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// End-to-end coverage of the W3-A policy layer against the FakeSatellite,
// over real sockets and the real 1 Hz alive tick (the deterministic
// tick-driven slices live in the Lifecycle*/ReconcileDriver* suites):
//
//   * enriched-ack reconcile driver (gap G9 policy side): benign epoch
//     drift adopts without a re-PUT; a genuine server-side slot loss
//     (injected out-of-band through the authed per-slot DELETE route)
//     self-heals — GET, divergence detected, full desired state re-PUT,
//     slot re-applied — within a couple of heartbeats.
//   * close-notify reason POLICY (gap G10): unpaired drops the key and
//     stops retrying (terminal-auth funnel, loud), replaced stays down
//     until the user acts, shutdown re-enters the exponential backoff and
//     recovers by itself.

import Combine
import DishCore
import XCTest
@testable import Dish

@MainActor
final class IntegrationReconcilePolicyTests: XCTestCase {

    private var satellite: FakeSatellite!
    private var ports: FakeSatellite.Ports!
    private var defaults: UserDefaults!
    private var defaultsName: String!
    private var store: ConnectionStore!
    private var manager: WifiConnectionManager!
    private var events: [ConnectionEvent] = []
    private var bag = Set<AnyCancellable>()

    private let keyHex = String(repeating: "1f", count: 32)

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
        satellite.pairingKeyHex = keyHex
        store.setSharedKey(keyHex, for: server.id)
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

    private var errorMessages: [String] {
        events.compactMap {
            if case let .error(message) = $0 { return message }
            return nil
        }
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
    private func connectAndAwaitLive(withSlot: Bool = false) async throws -> WifiConnection {
        if withSlot, manager.get(server.id) == nil {
            let conn = WifiConnection(id: server.id, server: server)
            manager.register(conn)
            conn.attachSlot("policy-slot", controllerType: 0, hasMotion: false, hasLight: false)
        }
        manager.connect(to: server)
        let live = await waitUntil { self.manager.get(self.server.id)?.state == .live }
        XCTAssertTrue(live, "keyed connect must reach .live: \(errorMessages)")
        let conn = try XCTUnwrap(manager.get(server.id))
        XCTAssertTrue(satellite.awaitHeartbeats(atLeast: 1), "reply path must be learned")
        return conn
    }

    // MARK: - Reconcile driver (G9 policy side)

    func testBenignEpochDriftAdoptsWithoutRePut() async throws {
        let conn = try await connectAndAwaitLive(withSlot: true)
        XCTAssertEqual(satellite.sessionPuts.count, 1)
        let getsBefore = satellite.reconcileGets.count

        // A server-side applied change that leaves OUR desired state intact
        // (e.g. the epoch tick of a sibling's converge): drift is detected,
        // the GET runs, the epoch is adopted — and no re-PUT follows.
        satellite.bumpEpoch()

        let reconciled = await waitUntil { self.satellite.reconcileGets.count > getsBefore }
        XCTAssertTrue(reconciled, "epoch drift must trigger the reconcile GET")
        let adopted = await waitUntil { conn.lastAppliedEpoch == Int(self.satellite.epoch) }
        XCTAssertTrue(adopted, "benign drift must adopt the server epoch")
        XCTAssertEqual(satellite.sessionPuts.count, 1, "benign drift must NOT re-PUT")
        XCTAssertEqual(conn.state, .live, "the session never blips for a benign adopt")
    }

    func testServerSideSlotLossSelfHealsViaGetAndRePut() async throws {
        let conn = try await connectAndAwaitLive(withSlot: true)
        XCTAssertEqual(satellite.appliedControllers.count, 1)
        XCTAssertEqual(satellite.sessionPuts.count, 1)

        // Unplug the applied slot server-side WITHOUT the client asking —
        // the involuntary-loss case (bus death / reap / admin action) the
        // contract's enriched-ack loop exists for. The authed per-slot
        // DELETE route stands in for the server-internal loss.
        let rest = FakeSatelliteRestScriptClient(satellite: satellite)
        let deviceId = store.getOrCreateDeviceId()
        let proof = manager.proofFor(server.id)
        let reply = try await rest.request(
            "DELETE",
            "/api/connections/\(satellite.connectionId)/controllers/0",
            headers: ["X-Device-Id": deviceId, "X-Hmac-Proof": proof]
        )
        XCTAssertEqual(reply.status, 200)
        XCTAssertTrue(satellite.appliedControllers.isEmpty, "the slot is gone server-side")

        // Self-heal: ack drift → GET → applied ≠ desired → full re-PUT →
        // the slot is applied again, all within a couple of heartbeats.
        let rePut = await waitUntil { self.satellite.sessionPuts.count >= 2 }
        XCTAssertTrue(rePut, "real divergence must re-PUT the full desired state")
        XCTAssertGreaterThanOrEqual(satellite.reconcileGets.count, 1, "the GET precedes the re-PUT")
        let healed = await waitUntil { self.satellite.appliedControllers.count == 1 }
        XCTAssertTrue(healed, "the lost slot must be re-applied")
        let liveAgain = await waitUntil { self.manager.get(self.server.id)?.state == .live }
        XCTAssertTrue(liveAgain, "the healed session ends live")
        let adopted = await waitUntil {
            self.manager.get(self.server.id)?.lastAppliedEpoch == Int(self.satellite.epoch)
        }
        XCTAssertTrue(adopted, "the re-PUT response epoch becomes the new compare baseline")
        _ = conn // keep the strong reference through the heal
    }

    // MARK: - Close-notify policy (G10)

    func testCloseUnpairedDropsKeyAndStopsRetrying() async throws {
        let conn = try await connectAndAwaitLive()
        var reasons: [CloseReason] = []
        conn.onSessionClose = { reasons.append($0) }
        let putsBefore = satellite.sessionPuts.count

        XCTAssertTrue(satellite.sendSessionClose(.unpaired))

        let surfaced = await waitUntil { reasons == [.unpaired] }
        XCTAssertTrue(surfaced, "the parsed reason must surface")
        let dropped = await waitUntil { self.store.sharedKey(for: self.server.id) == nil }
        XCTAssertTrue(dropped, "unpaired is trust revocation: the key must drop")
        XCTAssertTrue(manager.staleSatelliteIds.contains(server.id), "row parks on Needs pairing")
        let loud = await waitUntil {
            self.errorMessages.contains(WifiConnectionManager.repairNeededMessage)
        }
        XCTAssertTrue(loud, "an active server-side unpair is loud")
        XCTAssertEqual(manager.get(server.id)?.state, .idle)

        // The retry curve is STOPPED — no silent re-PUT ever fires (attempt 1
        // of a wrongly-armed backoff would land at ~1 s).
        XCTAssertNil(manager.retry[server.id], "terminal auth clears the retry state")
        try await Task.sleep(nanoseconds: 2_500_000_000)
        XCTAssertEqual(satellite.sessionPuts.count, putsBefore, "no retry may follow an unpair")
    }

    func testCloseReplacedStaysDownUntilUserActs() async throws {
        let conn = try await connectAndAwaitLive()
        var reasons: [CloseReason] = []
        conn.onSessionClose = { reasons.append($0) }
        let putsBefore = satellite.sessionPuts.count

        XCTAssertTrue(satellite.sendSessionClose(.replaced))

        let surfaced = await waitUntil { reasons == [.replaced] }
        XCTAssertTrue(surfaced)
        let down = await waitUntil { self.manager.get(self.server.id)?.state == .idle }
        XCTAssertTrue(down, "replaced tears down without a stale/backoff window")
        let suppressed = await waitUntil { self.manager.retry[self.server.id]?.suppressed == true }
        XCTAssertTrue(suppressed, "replaced parks the row out of every silent-retry path")
        XCTAssertNotNil(store.sharedKey(for: server.id), "replaced is not trust loss")

        // No silent reconnect: the replacement session (possibly another
        // device) must not be kicked by an auto-retry.
        try await Task.sleep(nanoseconds: 2_500_000_000)
        XCTAssertEqual(satellite.sessionPuts.count, putsBefore, "stay-down means STAY down")

        // Only user action lifts the suppression.
        manager.connect(to: server)
        let liveAgain = await waitUntil { self.manager.get(self.server.id)?.state == .live }
        XCTAssertTrue(liveAgain, "a user-initiated connect must reconnect after replaced")
        XCTAssertEqual(satellite.sessionPuts.count, putsBefore + 1)
        XCTAssertNotEqual(manager.retry[server.id]?.suppressed, true, "user action clears suppression")
    }

    func testCloseShutdownReentersBackoffAndRecovers() async throws {
        let conn = try await connectAndAwaitLive()
        var reasons: [CloseReason] = []
        conn.onSessionClose = { reasons.append($0) }
        let putsBefore = satellite.sessionPuts.count

        // The harness stays up (as a rebooting satellite would come back),
        // so the first backoff attempt (~1 s) must re-establish the session.
        XCTAssertTrue(satellite.sendSessionClose(.shutdown))

        let surfaced = await waitUntil { reasons == [.shutdown] }
        XCTAssertTrue(surfaced)
        let parked = await waitUntil { self.manager.get(self.server.id)?.state == .stale }
        XCTAssertTrue(parked, "shutdown parks on the Unsteady/stale backoff window, not Offline")

        let rePut = await waitUntil { self.satellite.sessionPuts.count >= putsBefore + 1 }
        XCTAssertTrue(rePut, "the backoff retry must re-PUT silently")
        let liveAgain = await waitUntil { self.manager.get(self.server.id)?.state == .live }
        XCTAssertTrue(liveAgain, "the session recovers on the retry curve")
        XCTAssertNil(manager.retry[server.id], "session success resets the backoff curve")
        XCTAssertFalse(
            errorMessages.contains(WifiConnectionManager.repairNeededMessage),
            "a transient shutdown close is never loud"
        )
        XCTAssertNotNil(store.sharedKey(for: server.id))
    }
}
