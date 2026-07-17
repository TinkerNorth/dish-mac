// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// Loopback end-to-end against the REAL satellite server binary — the
// dish-side driver for `scripts/e2e_local.sh`. Skipped unless the script's
// env contract is present (`DISH_E2E_LIVE=1`), so a plain `swift test` run
// never depends on an external process.
//
// What this proves that the FakeSatellite suites can't: the actual C++
// satellite accepts this client's pairing (path A, real rotating PIN), pins
// its real self-signed TLS cert, applies the declarative session PUT, and —
// the load-bearing bit — advances its own liveness state machine on this
// client's UDP frames, which only happens when the HKDF/AEAD bytes
// interoperate for real. Server-side truth is read from the loopback-only
// admin API (`:9877`), which needs no auth by design.
//
// Entitlement boundary: on an unentitled satellite build the virtual-pad
// backend is inert, so the controller slot applies as `backendUnavailable`
// and the heartbeat ack reports `backendAvailable == false`. The test
// branches on that in-band signal rather than assuming either build.

import Combine
import XCTest
@testable import Dish

@MainActor
final class IntegrationLiveSatelliteE2ETests: XCTestCase {

    private var defaults: UserDefaults!
    private var defaultsName: String!
    private var store: ConnectionStore!
    private var manager: WifiConnectionManager!
    private var events: [ConnectionEvent] = []
    private var bag = Set<AnyCancellable>()

    private var host = "127.0.0.1"
    private var restPort = 9443
    private var udpPort = 9876
    private var adminPort = 9877

    override func setUpWithError() throws {
        try super.setUpWithError()
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(
            env["DISH_E2E_LIVE"] == "1",
            "live-satellite e2e runs only under scripts/e2e_local.sh (DISH_E2E_LIVE=1)"
        )
        host = env["DISH_E2E_HOST"] ?? host
        restPort = env["DISH_E2E_REST_PORT"].flatMap(Int.init) ?? restPort
        udpPort = env["DISH_E2E_UDP_PORT"].flatMap(Int.init) ?? udpPort
        adminPort = env["DISH_E2E_ADMIN_PORT"].flatMap(Int.init) ?? adminPort

        defaultsName = "dish.e2e.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsName)
        store = ConnectionStore(defaults: defaults, keyStore: InMemoryKeyStore())
        manager = WifiConnectionManager(store: store)
        events = []
        manager.events
            .sink { [weak self] event in self?.events.append(event) }
            .store(in: &bag)
    }

    override func tearDown() {
        if let manager {
            for id in manager.connections.keys {
                manager.disconnect(id: id)
            }
        }
        if let defaults, let defaultsName {
            defaults.removePersistentDomain(forName: defaultsName)
        }
        bag.removeAll()
        super.tearDown()
    }

    private var server: DiscoveredServer {
        DiscoveredServer(
            name: "e2e-satellite",
            ip: host,
            udpPort: udpPort,
            pairPort: restPort,
            httpPort: restPort
        )
    }

    private var errorMessages: [String] {
        events.compactMap {
            if case let .error(message) = $0 { return message }
            return nil
        }
    }

    private func waitUntil(
        timeout: TimeInterval = 10,
        _ predicate: () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return predicate()
    }

    // MARK: - Admin-surface helpers (loopback :9877, no auth by design)

    private func adminJSON(_ path: String) async throws -> Any {
        let url = try XCTUnwrap(URL(string: "http://\(host):\(adminPort)\(path)"))
        let (data, response) = try await URLSession.shared.data(from: url)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 200, "admin \(path) must answer")
        return try JSONSerialization.jsonObject(with: data)
    }

    private func operatorPin() async throws -> String {
        let raw = try await adminJSON("/api/pin/status")
        let json = try XCTUnwrap(raw as? [String: Any])
        return try XCTUnwrap(json["currentPin"] as? String, "satellite must expose the rotating PIN")
    }

    private func adminConnectionRow(deviceId: String) async throws -> [String: Any]? {
        let raw = try await adminJSON("/api/connections")
        let rows = try XCTUnwrap(raw as? [[String: Any]])
        return rows.first { ($0["deviceId"] as? String) == deviceId }
    }

    private func adminDeviceIds() async throws -> [String] {
        let raw = try await adminJSON("/api/devices")
        let rows = try XCTUnwrap(raw as? [[String: Any]])
        return rows.compactMap { $0["deviceId"] as? String }
    }

    /// Bounded poll of an async admin predicate (the admin view trails the
    /// UDP path by up to one liveness tick).
    private func waitForAdmin(
        timeout: TimeInterval = 10,
        _ check: () async throws -> Bool
    ) async rethrows -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try await check() { return true }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return try await check()
    }

    // MARK: - The journey

    func testPairStreamAndTearDownAgainstTheRealSatellite() async throws {
        let pin = try await operatorPin()
        XCTAssertFalse(pin.isEmpty)
        let id = server.id
        let deviceId = store.getOrCreateDeviceId()

        // Bind a slot BEFORE pairing so the descriptor rides the very first
        // declarative session PUT.
        let conn = WifiConnection(id: id, server: server)
        manager.register(conn)
        conn.attachSlot("e2e-slot", controllerType: 0, hasMotion: false, hasLight: false)

        // Pair path A with the real rotating operator PIN → key lands →
        // openSession PUT → live.
        manager.pairWithPin(server, pin: pin)
        let keyed = await waitUntil { self.store.sharedKey(for: id) != nil }
        XCTAssertTrue(keyed, "path-A pairing against the real satellite must land the shared key")
        let live = await waitUntil { self.manager.get(id)?.state == .live }
        XCTAssertTrue(live, "the declarative PUT must reach .live: \(errorMessages)")

        // TOFU pinned the satellite's real self-signed cert on first contact.
        XCTAssertNotNil(store.certPin(host: host), "first HTTPS contact must pin the cert fingerprint")

        // The downlink decrypts: the enriched heartbeat ack round-trips
        // through the real server crypto within the first alive ticks.
        let acked = await waitUntil { conn.lastHeartbeatAck != nil }
        XCTAssertTrue(acked, "the enriched heartbeat ack must decrypt and surface")
        let ack = try XCTUnwrap(conn.lastHeartbeatAck)
        let entitled = ack.backendAvailable

        // Uplink streams: a burst of input reports + one touchpad frame.
        for i in 0 ..< 5 {
            conn.sendReport(
                buttons: 0x1000,
                lt: UInt8(i),
                rt: 0,
                lx: 1000,
                ly: -1000,
                rx: 0,
                ry: 0
            )
        }
        conn.sendTouchpad(
            finger0Active: true,
            finger0Id: 1,
            finger0X: 320,
            finger0Y: -240,
            finger1Active: false,
            finger1Id: 0,
            finger1X: 0,
            finger1Y: 0,
            buttonPressed: false,
            eventTimeMs: 12345
        )

        // Server-side truth (admin surface): our session row exists and is
        // ACTIVE — the satellite's liveness machine only advances on frames
        // it actually decrypted, so this is the cross-implementation crypto
        // proof, not just a REST echo.
        let active = try await waitForAdmin {
            let row = try await self.adminConnectionRow(deviceId: deviceId)
            return (row?["state"] as? String) == "active"
        }
        XCTAssertTrue(active, "the real satellite must mark this session active off decrypted UDP")
        let maybeRow = try await adminConnectionRow(deviceId: deviceId)
        let row = try XCTUnwrap(maybeRow)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(row["epoch"] as? Int), 1)

        // Slot outcome depends on the entitlement boundary (see header).
        let controllers = try XCTUnwrap(row["controllers"] as? [[String: Any]])
        let anyPlugged = controllers.contains { ($0["pluggedIn"] as? Bool) == true }
        if entitled {
            XCTAssertTrue(anyPlugged, "entitled backend must plug the declared slot")
        } else {
            XCTAssertFalse(anyPlugged, "unentitled backend applies the slot as backendUnavailable")
            let surfaced = await waitUntil(timeout: 2) {
                self.errorMessages.contains("Server could not apply the controller")
            }
            XCTAssertTrue(surfaced, "the apply failure must surface, not vanish")
        }

        // Latency window seeded from real heartbeat RTTs.
        let seeded = await waitUntil { (conn.client?.latencySnapshot().samples ?? 0) >= 1 }
        XCTAssertTrue(seeded, "heartbeat acks must land RTT samples")

        // Graceful close: DELETE /api/connections/{id}; the admin row drains.
        manager.disconnect(id: id)
        let drained = try await waitForAdmin {
            try await self.adminConnectionRow(deviceId: deviceId) == nil
        }
        XCTAssertTrue(drained, "graceful DELETE must remove the session server-side")

        // Forget → self-unpair: the satellite's paired-device list drops us.
        manager.forget(id: id)
        let unpaired = try await waitForAdmin {
            try await !self.adminDeviceIds().contains(deviceId)
        }
        XCTAssertTrue(unpaired, "forget must DELETE /api/pair so the operator list stays truthful")
        XCTAssertNil(store.sharedKey(for: id))
    }
}
