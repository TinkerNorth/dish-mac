// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// Manager-level data-plane flows against FakeSatellite — the live loops the
// deterministic client tests deliberately skip: real heartbeat timer + receive
// loop, uplink frames decrypting against the harness's INDEPENDENT CryptoKit
// implementation (G1/G2 cross-checked), the enriched-ack snapshot poll (G9
// parse), close-notify reasons through WifiConnection (G10 parse), latency
// seeding (G13), the proactive re-key re-PUT (G4), and the REST slot converge
// that replaced UDP registration (D5 + the W2-A descriptor seam).

import Combine
import DishCore
import XCTest
@testable import Dish

@MainActor
final class WifiConnectionManagerDataPlaneTests: XCTestCase {

    private var satellite: FakeSatellite!
    private var ports: FakeSatellite.Ports!
    private var defaults: UserDefaults!
    private var defaultsName: String!
    private var store: ConnectionStore!
    private var manager: WifiConnectionManager!

    override func setUpWithError() throws {
        try super.setUpWithError()
        satellite = try FakeSatellite()
        ports = try satellite.start()
        defaultsName = "dish.test.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsName)
        store = ConnectionStore(defaults: defaults, keyStore: InMemoryKeyStore())
        manager = WifiConnectionManager(store: store)
        // Plant matching trust material on both ends (skips the PIN dance).
        let keyHex = String(repeating: "1f", count: 32)
        satellite.pairingKeyHex = keyHex
        store.setSharedKey(keyHex, for: server.id)
    }

    override func tearDown() {
        for id in manager.connections.keys {
            manager.disconnect(id: id)
        }
        satellite.stop()
        defaults.removePersistentDomain(forName: defaultsName)
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

    // MARK: - Encrypted uplink decrypts server-side (G1/G2, independent impl)

    func testHeartbeatsAndInputDecryptAgainstTheIndependentServerCrypto() async throws {
        let conn = try await connectAndAwaitLive()

        // The first heartbeat fires immediately on session start.
        XCTAssertTrue(satellite.awaitHeartbeats(atLeast: 1), "uplink heartbeat must decrypt server-side")

        conn.sendReport(buttons: 0x1000, lt: 9, rt: 0, lx: 5, ly: -5, rx: 0, ry: 0)
        let frame = try XCTUnwrap(satellite.awaitFrame(opcode: FakeSatelliteOpcode.input))
        guard case let .input(ctrlIdx, report) = frame.detail else {
            return XCTFail("input frame must parse as .input, got \(frame.detail)")
        }
        XCTAssertEqual(ctrlIdx, 0)
        XCTAssertEqual(report.count, 12, "XUSB report body")
        XCTAssertEqual(satellite.authFailDrops, 0, "every uplink frame authenticated cleanly")
        XCTAssertEqual(satellite.unknownTokenDrops, 0)
    }

    func testTouchpadUplinkArrivesAsSixteenByteFrameServerSide() async throws {
        let conn = try await connectAndAwaitLive()
        conn.sendTouchpad(
            finger0Active: true,
            finger0Id: 4,
            finger0X: 100,
            finger0Y: -100,
            finger1Active: false,
            finger1Id: 0,
            finger1X: 0,
            finger1Y: 0,
            buttonPressed: false,
            eventTimeMs: 0x1234_5678
        )
        let frame = try XCTUnwrap(satellite.awaitFrame(opcode: FakeSatelliteOpcode.touchpad))
        guard case let .touchpad(decoded) = frame.detail else {
            return XCTFail("16-byte touchpad payload must parse, got \(frame.detail)")
        }
        XCTAssertEqual(decoded.finger0Id, 4)
        XCTAssertEqual(decoded.eventTimeMs, 0x1234_5678, "trailing eventTimeMs survives the wire")
    }

    // MARK: - Enriched-ack snapshot poll (G9 parse side)

    func testAliveTickPublishesInjectedEpochAndBitmap() async throws {
        satellite.ackEpochOverride = 77
        satellite.ackBitmapOverride = 0b101
        satellite.ackCountOverride = 2
        satellite.ackBackendAvailableOverride = false

        let conn = try await connectAndAwaitLive()
        let published = await waitUntil { conn.lastHeartbeatAck?.epoch == 77 }
        XCTAssertTrue(published, "the 1 Hz alive tick must surface the enriched ack")
        let ack = try XCTUnwrap(conn.lastHeartbeatAck)
        XCTAssertEqual(ack.bitmap, 0b101)
        XCTAssertEqual(ack.activeCount, 2)
        XCTAssertFalse(ack.backendAvailable)
    }

    // MARK: - Latency seeding (G13)

    func testLatencyWindowSeedsFromLiveHeartbeats() async throws {
        let conn = try await connectAndAwaitLive()
        XCTAssertTrue(satellite.awaitHeartbeats(atLeast: 1))
        let seeded = await waitUntil { (conn.client?.latencySnapshot().samples ?? 0) >= 1 }
        XCTAssertTrue(seeded, "acked heartbeats must land RTT samples")
        let snapshot = try XCTUnwrap(conn.client?.latencySnapshot())
        let p50 = try XCTUnwrap(snapshot.p50OneWayMs)
        XCTAssertGreaterThanOrEqual(p50, 0)
        XCTAssertLessThan(p50, 2500, "loopback latency sits far under the loss cap")
    }

    // MARK: - Close notify through WifiConnection (G10 parse side)

    func testCloseNotifyReasonSurfacesThroughConnection() async throws {
        let conn = try await connectAndAwaitLive()
        var received: [CloseReason] = []
        conn.onSessionClose = { received.append($0) }
        XCTAssertTrue(satellite.awaitHeartbeats(atLeast: 1), "the reply path must be learned first")

        XCTAssertTrue(satellite.sendSessionClose(.kicked))
        let surfaced = await waitUntil { received == [.kicked] }
        XCTAssertTrue(surfaced, "the parsed close reason must reach the session layer")

        // The client latched dead immediately; the alive tick reaps without
        // waiting out the 5-miss death window (~10 s).
        let reaped = await waitUntil(timeout: 4) { self.manager.get(self.server.id)?.state != .live }
        XCTAssertTrue(reaped, "close-notify must mark the session dead within a tick")
    }

    // MARK: - Proactive re-key (G4)

    func testSendCounterNearExhaustionTriggersRePutAndKeyRotation() async throws {
        let conn = try await connectAndAwaitLive()
        let firstToken = try XCTUnwrap(satellite.lastTokenHex)
        XCTAssertEqual(satellite.sessionPuts.count, 1)

        // Park the send counter past the 0xF0000000 threshold — the next
        // 1 Hz tick fires onRekeyNeeded exactly once.
        try XCTUnwrap(conn.client).counter.set(UInt64(ProtocolConstants.counterRepushThreshold))

        let rePut = await waitUntil { self.satellite.sessionPuts.count >= 2 }
        XCTAssertTrue(rePut, "the manager must re-PUT before the counter can exhaust")
        let rotated = await waitUntil { self.satellite.lastTokenHex != firstToken }
        XCTAssertTrue(rotated, "the re-PUT rotates token/salt/key")

        // Same socket, fresh counters: the session stays live and the fresh
        // uplink decrypts under the NEW material.
        let stillLive = await waitUntil { self.manager.get(self.server.id)?.state == .live }
        XCTAssertTrue(stillLive)
        let counterReset = await waitUntil {
            let sent = conn.client?.sendCounter ?? .max
            return sent < ProtocolConstants.counterRepushThreshold
        }
        XCTAssertTrue(counterReset, "counters restart at 1 after the re-key")
        let heartbeatsBefore = satellite.heartbeatCount
        XCTAssertTrue(
            satellite.awaitHeartbeats(atLeast: heartbeatsBefore + 1, timeout: 4),
            "post-re-key heartbeats must decrypt under the rotated key"
        )
        XCTAssertFalse(conn.state == .stale, "re-key must not bounce the session")
    }

    // MARK: - Slot converge over REST (D5: no UDP registration)

    func testAttachedSlotRidesTheSessionPut() async throws {
        // Bind BEFORE the session opens: the descriptor must ride the
        // declarative PUT itself (the W2-A :337 seam).
        let conn = WifiConnection(id: server.id, server: server)
        manager.register(conn)
        conn.attachSlot("slot-a", controllerType: 0, hasMotion: true, hasLight: false)

        _ = try await connectAndAwaitLive()

        let put = try XCTUnwrap(satellite.sessionPuts.first)
        let controllers = try XCTUnwrap(put["controllers"] as? [[String: Any]])
        XCTAssertEqual(controllers.count, 1)
        XCTAssertEqual(controllers.first?["ctrlIdx"] as? Int, 0)
        let caps = try XCTUnwrap(controllers.first?["caps"] as? [String: Any])
        XCTAssertEqual(caps["motion"] as? Bool, true)
        XCTAssertEqual(caps["lightbar"] as? Bool, false)
        XCTAssertEqual(caps["rumble"] as? Bool, true)
        XCTAssertEqual(caps["analogTriggers"] as? Bool, true)
        XCTAssertEqual(controllers.first?["touchpadMode"] as? String, "off")
        XCTAssertEqual(satellite.appliedControllers.count, 1, "the server applied the slot")
    }

    func testLiveAttachAndDetachConvergeViaPerSlotRoutes() async throws {
        let conn = try await connectAndAwaitLive()
        XCTAssertTrue(satellite.appliedControllers.isEmpty, "zero-controller session first")
        let epochBefore = satellite.epoch

        conn.attachSlot("slot-a", controllerType: 0, hasMotion: false, hasLight: true)
        let applied = await waitUntil { self.satellite.appliedControllers.count == 1 }
        XCTAssertTrue(applied, "live attach must PUT the slot without a session re-PUT")
        XCTAssertEqual(satellite.sessionPuts.count, 1, "per-slot converge does not rotate the session")
        XCTAssertEqual(satellite.epoch, epochBefore &+ 1, "applied-topology change bumps the epoch")
        XCTAssertEqual(
            satellite.appliedControllers.first?["ctrlIdx"] as? Int,
            0
        )

        conn.detachSlot()
        let removed = await waitUntil { self.satellite.appliedControllers.isEmpty }
        XCTAssertTrue(removed, "live detach must DELETE the slot; the session lives on")
        XCTAssertEqual(manager.get(server.id)?.state, .live)
    }
}
