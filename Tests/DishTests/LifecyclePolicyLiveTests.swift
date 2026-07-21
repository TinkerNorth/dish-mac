// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// Live state-entry proofs for the previously-unreachable lifecycle states
// (gaps G14/G15, G10 policy) against the W1-C FakeSatellite: REAL heartbeat
// timers and receive loops, missed heartbeats produced by actually silencing
// the satellite, close reasons injected over the encrypted downlink, and the
// ConnectionHub chip derivations the states drive. Bounded predicate waits
// only — no bare sleeps.

import Combine
import DishCore
import XCTest
@testable import Dish

@MainActor
final class LifecyclePolicyLiveTests: XCTestCase {

    private var satellite: FakeSatellite!
    private var ports: FakeSatellite.Ports!
    private var defaults: UserDefaults!
    private var defaultsName: String!
    private var store: ConnectionStore!
    private var manager: WifiConnectionManager!
    private var hub: ConnectionHub!
    private var events: [ConnectionEvent] = []
    private var bag = Set<AnyCancellable>()

    override func setUpWithError() throws {
        try super.setUpWithError()
        satellite = try FakeSatellite()
        ports = try satellite.start()
        try satellite.requireHTTPSTransport()
        defaultsName = "dish.test.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsName)
        store = ConnectionStore(defaults: defaults, keyStore: InMemoryKeyStore())
        manager = WifiConnectionManager(store: store)
        hub = ConnectionHub(wifi: manager, store: store)
        events = []
        manager.events
            .sink { [weak self] event in self?.events.append(event) }
            .store(in: &bag)
        // Plant matching trust material on both ends (skips the PIN dance).
        let keyHex = String(repeating: "1f", count: 32)
        satellite.pairingKeyHex = keyHex
        store.setSharedKey(keyHex, for: server.id)
    }

    override func tearDown() {
        for id in manager.connections.keys {
            manager.disconnect(id: id) // also clears armed retries
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
    private func connectAndAwaitLive() async throws -> WifiConnection {
        manager.connect(to: server)
        let live = await waitUntil { self.manager.get(self.server.id)?.state == .live }
        XCTAssertTrue(live, "keyed connect must reach .live")
        return try XCTUnwrap(manager.get(server.id))
    }

    // MARK: - Faltering + UI unstable + stale window (gap G15)

    func testMissedHeartbeatsEnterFalteringThenUnstableChipThenStaleDeath() async throws {
        let conn = try await connectAndAwaitLive()
        XCTAssertTrue(satellite.awaitHeartbeats(atLeast: 1))

        // Silence the satellite: heartbeats keep firing, acks stop — the
        // REAL not-responding path, produced by the wire, not by test pokes.
        satellite.stop()

        let faltering = await waitUntil(timeout: 10) { conn.state == .faltering }
        XCTAssertTrue(faltering, "2 consecutive real misses must enter .faltering")
        let unstable = await waitUntil(timeout: 2) { self.hub.summary(self.server.id)?.live == .unstable }
        XCTAssertTrue(unstable, "the row chip must read Unsteady while faltering")

        // Accelerate the remaining misses (no acks can arrive — the server
        // is gone, so this cannot race a reset): the next real heartbeat
        // crosses the death threshold.
        conn.client?.missedAcks.set(ProtocolConstants.heartbeatMissMax - 1)
        let parked = await waitUntil(timeout: 6) { conn.state == .stale }
        XCTAssertTrue(parked, "death parks the wire state on .stale (silent-retry window)")
        XCTAssertNil(conn.client, "the dead client is torn down")
        XCTAssertGreaterThanOrEqual(
            manager.retry[server.id]?.attempt ?? 0,
            1,
            "death enters the backoff curve"
        )
        // .stale also reads Unsteady — the row stays live-ish through the
        // backoff window instead of flicking to Offline.
        let stillUnstable = await waitUntil(timeout: 2) { self.hub.summary(self.server.id)?.live == .unstable }
        XCTAssertTrue(stillUnstable)
        XCTAssertFalse(
            errorMessages.contains { $0.hasPrefix("Error:") },
            "death retries are silent — no banner the user didn't ask for"
        )
    }

    // MARK: - Close reasons end-to-end (gap G10 policy)

    // MARK: - Latency readout reaches the row summary (gap G13)

    func testHubSummaryCarriesLatencyReadoutWhileLive() async throws {
        let conn = try await connectAndAwaitLive()
        let sampled = await waitUntil { conn.latencySamples >= 1 && conn.latencyOneWayMs != nil }
        XCTAssertTrue(sampled, "heartbeat acks must seed the readout")
        let surfaced = await waitUntil(timeout: 4) {
            self.hub.summary(self.server.id)?.latencyMs != nil
        }
        XCTAssertTrue(surfaced, "the row summary must carry the latency readout")
        XCTAssertEqual(hub.summary(server.id)?.latencyMs, conn.latencyOneWayMs)
    }

    func testKickedCloseParksStaleThenHealsThroughBackoff() async throws {
        let conn = try await connectAndAwaitLive()
        XCTAssertTrue(satellite.awaitHeartbeats(atLeast: 1))
        XCTAssertEqual(satellite.sessionPuts.count, 1)

        XCTAssertTrue(satellite.sendSessionClose(.kicked))

        let parked = await waitUntil(timeout: 4) { conn.state == .stale }
        XCTAssertTrue(parked, "kicked is transient: park Unsteady, then retry")
        // The satellite is still up: the armed 1 s backoff retry re-PUTs and
        // the session heals without any user action.
        let healed = await waitUntil { self.satellite.sessionPuts.count >= 2 && conn.state == .live }
        XCTAssertTrue(healed, "the backoff retry must re-establish the session")
        XCTAssertFalse(
            errorMessages.contains { $0.hasPrefix("Error:") },
            "the kicked→retry cycle is silent"
        )
    }

    func testReplacedCloseParksSuppressedUntilUserConnects() async throws {
        let conn = try await connectAndAwaitLive()
        XCTAssertTrue(satellite.awaitHeartbeats(atLeast: 1))

        XCTAssertTrue(satellite.sendSessionClose(.replaced))

        let parked = await waitUntil(timeout: 4) {
            conn.state == .idle && self.manager.retry[self.server.id]?.suppressed == true
        }
        XCTAssertTrue(parked, "replaced parks the row out of every silent-retry path")

        // Neither the armed-retry path nor autoReconnectAll may touch a
        // suppressed row — a newer session owns the satellite.
        manager.autoReconnectAll()
        let resurrected = await waitUntil(timeout: 2) { self.satellite.sessionPuts.count >= 2 }
        XCTAssertFalse(resurrected, "suppressed rows must not auto-reconnect")
        XCTAssertEqual(conn.state, .idle)

        // The user outranks the suppression.
        manager.connect(to: server)
        let relive = await waitUntil { conn.state == .live }
        XCTAssertTrue(relive, "a user-initiated connect lifts the replaced parking")
        XCTAssertEqual(satellite.sessionPuts.count, 2)
    }

    func testUnpairedCloseDropsKeyAndParksNeedsPairing() async throws {
        let conn = try await connectAndAwaitLive()
        XCTAssertTrue(satellite.awaitHeartbeats(atLeast: 1))

        XCTAssertTrue(satellite.sendSessionClose(.unpaired))

        let keyDropped = await waitUntil(timeout: 4) { self.store.sharedKey(for: self.server.id) == nil }
        XCTAssertTrue(keyDropped, "close-notify(unpaired) revokes trust — the key must drop")
        XCTAssertTrue(manager.staleSatelliteIds.contains(server.id))
        XCTAssertEqual(conn.state, .idle)
        XCTAssertNil(manager.retry[server.id], "no silent retry against a server that revoked us")
        XCTAssertEqual(
            store.remembered().first { $0.id == self.server.id }?.id,
            server.id,
            "the remembered row SURVIVES — only the key drops"
        )
        // The satellite actively kicked this device out — that is loud.
        let surfaced = await waitUntil(timeout: 2) {
            self.errorMessages.contains(WifiConnectionManager.repairNeededMessage)
        }
        XCTAssertTrue(surfaced)
        // And the hub chip parks on "Needs pairing".
        let chip = await waitUntil(timeout: 2) { self.hub.summary(self.server.id)?.live == .stale }
        XCTAssertTrue(chip, "the row must read Needs pairing, not Offline")
    }
}
