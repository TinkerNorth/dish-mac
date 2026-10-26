// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// End-to-end session journeys against the FakeSatellite — whole protocol-1
// flows chained the way a user would hit them, socket-bounded by the
// harness's `await*` waiters (no sleeps). The per-feature slices live in the
// control-plane / data-plane suites; these tests prove the STAGES COMPOSE:
//
//   pair (operator PIN path A, incl. a wrong-PIN detour / client PIN path B
//   with the status poll) → declarative PUT topology → encrypted controller
//   input the harness decrypts and records byte-for-byte → enriched-ack
//   snapshot → latency seeding → graceful teardown. Plus the two terminal
//   control-plane arms end-to-end: a TOFU imposter aborts the handshake
//   without leaking a request (and without costing trust), and a pair-time
//   protocol-version 409 surfaces the version-mismatch UX without minting
//   trust.

import Combine
import DishCore
import XCTest
@testable import DishEngine

@MainActor
final class IntegrationSessionLifecycleTests: XCTestCase {

    private var satellite: FakeSatellite!
    private var ports: FakeSatellite.Ports!
    private var defaults: UserDefaults!
    private var defaultsName: String!
    private var store: ConnectionStore!
    private var manager: WifiConnectionManager!
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
        manager = WifiConnectionManager(
            store: store,
            approvalPolling: WifiConnectionManager.ApprovalPolling(intervalMs: 50, timeoutMs: 120_000)
        )
        events = []
        manager.events
            .sink { [weak self] event in self?.events.append(event) }
            .store(in: &bag)
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

    private func server(for satellite: FakeSatellite, ports: FakeSatellite.Ports) -> DiscoveredServer {
        DiscoveredServer(
            name: "Fake",
            ip: "127.0.0.1",
            udpPort: Int(ports.udp),
            pairPort: Int(ports.rest),
            httpPort: Int(ports.rest),
            machineId: satellite.machineId
        )
    }

    private var server: DiscoveredServer {
        server(for: satellite, ports: ports)
    }

    private var failures: [ConnectionFailure] {
        events.compactMap {
            switch $0 {
            case let .failure(failure), let .pairingFailed(_, failure): failure
            case .pairingRequired: nil
            }
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

    // MARK: - Journey: operator PIN (path A)

    func testFullJourneyOperatorPinPathA() async throws {
        let id = server.id
        await refuseAWrongPin(id: id)
        let conn = boundConnection(id: id)
        try await pairWithTheRealPin(id: id)
        try assertTheFirstPutCarriedTheWholeSlot()
        var closeReasons: [CloseReason] = []
        conn.onSessionClose = { closeReasons.append($0) }
        try assertEncryptedInputRoundTrips(conn)
        try assertTouchpadFrameRoundTrips(conn)
        try await assertAckAndLatencySeed(conn)
        await assertGracefulCloseDeletesTheSession(id: id, conn: conn)
        XCTAssertTrue(closeReasons.isEmpty, "a graceful close must never ride a close-notify")
    }

    /// A wrong PIN: the satellite refuses, the failure surfaces, no trust is minted.
    private func refuseAWrongPin(id: String) async {
        manager.pairWithPin(server, pin: "0000")
        let refused = await waitUntil { !self.failures.isEmpty }
        XCTAssertTrue(refused, "a wrong PIN must surface a pairing error")
        XCTAssertNil(store.sharedKey(for: id), "a refused PIN must not store a key")
        XCTAssertNil(satellite.pairingKeyHex, "the satellite must not mint trust for a wrong PIN")
    }

    /// The slot is bound before pairing so the descriptor rides the very
    /// first declarative PUT rather than a follow-up converge.
    private func boundConnection(id: String) -> WifiConnection {
        let conn = manager.get(id) ?? {
            let fresh = WifiConnection(id: id, server: server)
            manager.register(fresh)
            return fresh
        }()
        conn.attachSlot("journey-slot", controllerType: 0, capabilities: ControllerCapabilities(hasMotion: true, hasLightbar: true))
        return conn
    }

    private func pairWithTheRealPin(id: String) async throws {
        manager.pairWithPin(server, pin: satellite.operatorPin)
        let keyed = await waitUntil { self.store.sharedKey(for: id) != nil }
        XCTAssertTrue(keyed, "path A must land the shared key")
        XCTAssertEqual(store.sharedKey(for: id), satellite.pairingKeyHex, "both ends hold the SAME key")
        let live = await waitUntil { self.manager.get(id)?.state == .live }
        XCTAssertTrue(live, "pairing must flow straight into the live session")
    }

    private func assertTheFirstPutCarriedTheWholeSlot() throws {
        XCTAssertEqual(satellite.sessionPuts.count, 1)
        let put = try XCTUnwrap(satellite.sessionPuts.first)
        XCTAssertEqual(put["protocolVersion"] as? Int, ProtocolConstants.protocolVersion)
        XCTAssertEqual(put["deviceId"] as? String, store.getOrCreateDeviceId())
        let descriptors = try XCTUnwrap(put["controllers"] as? [[String: Any]])
        XCTAssertEqual(descriptors.count, 1)
        let caps = try XCTUnwrap(descriptors.first?["caps"] as? [String: Any])
        XCTAssertEqual(caps["motion"] as? Bool, true)
        XCTAssertEqual(caps["lightbar"] as? Bool, true)
        XCTAssertEqual(satellite.appliedControllers.count, 1, "the harness applied the slot")
    }

    /// The harness decrypts with its independent crypto and records the exact
    /// XUSB bytes.
    private func assertEncryptedInputRoundTrips(_ conn: WifiConnection) throws {
        XCTAssertTrue(satellite.awaitHeartbeats(atLeast: 1), "uplink heartbeat must decrypt")
        conn.sendReport(GamepadReport(buttons: 0x0405, lt: 7, rt: 9, lx: 1000, ly: -2, rx: 3, ry: -4))
        let inputFrame = try XCTUnwrap(satellite.awaitFrame(opcode: FakeSatelliteOpcode.input))
        guard case let .input(ctrlIdx, report) = inputFrame.detail else {
            return XCTFail("input frame must parse as .input, got \(inputFrame.detail)")
        }
        XCTAssertEqual(ctrlIdx, 0)
        XCTAssertEqual(
            Array(report),
            [0x05, 0x04, 0x07, 0x09, 0xE8, 0x03, 0xFE, 0xFF, 0x03, 0x00, 0xFC, 0xFF],
            "the decrypted XUSB report must match byte-for-byte"
        )
    }

    private func assertTouchpadFrameRoundTrips(_ conn: WifiConnection) throws {
        conn.sendTouchpad(
            sample: TouchpadSample(
                finger0: TouchpadFinger(active: true, id: 2, x: -100, y: 200),
                finger1: TouchpadFinger(active: true, id: 3, x: 400, y: -500),
                buttonPressed: true
            ),
            eventTimeMs: 0xCAFE_F00D
        )
        let padFrame = try XCTUnwrap(satellite.awaitFrame(opcode: FakeSatelliteOpcode.touchpad))
        guard case let .pointer(pad) = padFrame.detail else {
            return XCTFail("a version-3 session streams the POINTER frame, got \(padFrame.detail)")
        }
        XCTAssertEqual(pad.eventTimeMs, 0xCAFE_F00D)
        XCTAssertEqual(pad.fingerFlags, 0b11, "f0 active | f1 active")
        XCTAssertEqual(pad.buttons, ProtocolConstants.pointerButtonLeft, "the click is the left button")
        XCTAssertEqual(pad.finger1X, 400)
    }

    private func assertAckAndLatencySeed(_ conn: WifiConnection) async throws {
        let acked = await waitUntil { conn.lastHeartbeatAck != nil }
        XCTAssertTrue(acked, "the enriched ack must surface through the tick")
        let ack = try XCTUnwrap(conn.lastHeartbeatAck)
        XCTAssertEqual(ack.epoch, satellite.epoch, "ack epoch mirrors the server's applied epoch")
        XCTAssertEqual(ack.bitmap, 0b1, "slot 0 is active server-side")
        let seeded = await waitUntil { (conn.client?.latencySnapshot().samples ?? 0) >= 1 }
        XCTAssertTrue(seeded, "heartbeat RTTs must seed the latency window")
        let p50 = try XCTUnwrap(conn.client?.latencySnapshot().p50OneWayMs)
        XCTAssertGreaterThanOrEqual(p50, 0)
        XCTAssertLessThan(p50, 2500)
    }

    /// `DELETE /api/connections/{id}`: the satellite drops the session, slots
    /// unplug, the epoch bumps, and the pairing survives.
    private func assertGracefulCloseDeletesTheSession(id: String, conn: WifiConnection) async {
        let epochBeforeClose = satellite.epoch
        manager.disconnect(id: id)
        let deleted = await waitUntil { self.satellite.lastTokenHex == nil }
        XCTAssertTrue(deleted, "graceful close must DELETE the session server-side")
        XCTAssertTrue(satellite.appliedControllers.isEmpty, "teardown unplugs the applied slot")
        XCTAssertEqual(satellite.epoch, epochBeforeClose &+ 1, "unplugging bumps the epoch")
        XCTAssertEqual(manager.get(id)?.state, .idle)
        XCTAssertNotNil(store.sharedKey(for: id), "disconnect keeps the pairing")
    }

    // MARK: - Journey: client PIN (path B)

    func testFullJourneyClientPinPathB() async {
        let id = server.id
        satellite.pairingKeyHex = nil

        manager.pairWithClientPin(server, clientPin: "4321")
        let submitted = await waitUntil { self.satellite.lastClientPin == "4321" }
        XCTAssertTrue(submitted, "the client PIN must reach the satellite")

        // The key must only arrive via the status poll (single-use staged
        // approval) — prove the poll actually ran before approving.
        let polled = await waitUntil { self.satellite.pairStatusPolls >= 1 }
        XCTAssertTrue(polled, "path B must poll GET /api/pair/status while pending")
        XCTAssertNil(store.sharedKey(for: id), "no key before the operator approves")

        satellite.approveClientPin()
        let keyed = await waitUntil { self.store.sharedKey(for: id) != nil }
        XCTAssertTrue(keyed, "approval must hand the staged key over exactly once")
        XCTAssertEqual(store.sharedKey(for: id), satellite.pairingKeyHex)

        // Approval flows into the session PUT and all the way onto the wire.
        let live = await waitUntil { self.manager.get(id)?.state == .live }
        XCTAssertTrue(live)
        XCTAssertEqual(satellite.sessionPuts.count, 1)
        XCTAssertTrue(satellite.awaitHeartbeats(atLeast: 1), "the path-B key must encrypt real traffic")
        XCTAssertEqual(satellite.authFailDrops, 0)
    }

    // MARK: - TOFU imposter (mismatched certificate)

    func testImposterCertificateRejectedWithoutCostingTrust() async throws {
        let id = server.id

        // Establish real trust with the genuine satellite (pin lands for the
        // host on first HTTPS contact), then take it down.
        satellite.pairingKeyHex = String(repeating: "1f", count: 32)
        store.setSharedKey(String(repeating: "1f", count: 32), for: id)
        manager.connect(to: server)
        let live = await waitUntil { self.manager.get(id)?.state == .live }
        XCTAssertTrue(live)
        let pinned = try XCTUnwrap(store.certPin(host: "127.0.0.1"))
        XCTAssertEqual(pinned, satellite.certificateFingerprintSHA256Hex.lowercased())
        manager.disconnect(id: id)
        satellite.stop()

        // An imposter on the same host answering under the SAME satellite
        // identity, but with a different runtime-minted certificate.
        let imposter = try FakeSatellite(machineId: satellite.machineId)
        let imposterPorts = try imposter.start()
        defer { imposter.stop() }
        XCTAssertNotEqual(
            imposter.certificateFingerprintSHA256Hex,
            satellite.certificateFingerprintSHA256Hex,
            "the imposter must present different cert material"
        )
        imposter.pairingKeyHex = store.sharedKey(for: id)

        // Keyed reconnect: the pinning delegate aborts the TLS handshake
        // BEFORE any request bytes flow — the session PUT never reaches the
        // imposter, and the abort costs no trust.
        let imposterServer = server(for: imposter, ports: imposterPorts)
        manager.connect(to: imposterServer)
        let failed = await waitUntil { self.manager.get(id)?.state == .idle && !self.failures.isEmpty }
        XCTAssertTrue(failed, "the keyed connect against the imposter must fail loudly")
        XCTAssertTrue(imposter.sessionPuts.isEmpty, "no request bytes may reach the imposter")
        XCTAssertTrue(imposter.frames.isEmpty)
        XCTAssertNotNil(store.sharedKey(for: id), "an imposter must not cost the stored pairing")
        XCTAssertEqual(store.certPin(host: "127.0.0.1"), pinned, "the original pin stays authoritative")
        XCTAssertFalse(manager.staleSatelliteIds.contains(id), "no 'Needs pairing' for an imposter")

        // Pair-time attempt against the imposter: the same handshake abort
        // surfaces the honest "identity changed" message (the recorded
        // mismatch breadcrumb), never a PIN prompt or a bare "unreachable".
        manager.pairWithPin(imposterServer, pin: satellite.operatorPin)
        let surfaced = await waitUntil {
            self.failures.contains(.identityChanged)
        }
        XCTAssertTrue(surfaced, "a pin mismatch must read as an identity change")
        XCTAssertNil(imposter.pairedDeviceId, "the imposter must never see a pair request either")
        XCTAssertNotNil(store.sharedKey(for: id), "trust still intact after the pair-time abort")
    }

    /// The KEYED reconnect path must surface the same identity-changed UX the
    /// pair paths do (gap G7 UX parity; W4A-F1): a TOFU mismatch is an
    /// identity problem, not a connectivity one, so the generic "connection
    /// failed" must never stand in for it. And it must not feed the silent
    /// retry curve — backoff can't outrun a changed identity; only the user
    /// (re-pair / forget) can resolve it. Mirrors dish-android's keyed-path
    /// `failSession(..., IDENTITY_CHANGED_MSG, retry = false)`.
    func testKeyedConnectAgainstImposterSurfacesIdentityChangeAndStopsRetry() async throws {
        let id = server.id

        // Real trust first: the genuine satellite pins its cert, then goes down.
        satellite.pairingKeyHex = String(repeating: "2b", count: 32)
        store.setSharedKey(String(repeating: "2b", count: 32), for: id)
        manager.connect(to: server)
        let live = await waitUntil { self.manager.get(id)?.state == .live }
        XCTAssertTrue(live)
        manager.disconnect(id: id)
        satellite.stop()

        // Same satellite identity, different runtime-minted certificate.
        let imposter = try FakeSatellite(machineId: satellite.machineId)
        let imposterPorts = try imposter.start()
        defer { imposter.stop() }
        imposter.pairingKeyHex = store.sharedKey(for: id)
        let imposterServer = server(for: imposter, ports: imposterPorts)

        // USER-INITIATED keyed connect: the pre-request abort must read as an
        // identity change, never the generic transport failure.
        manager.connect(to: imposterServer)
        let surfaced = await waitUntil {
            self.failures.contains(.identityChanged)
        }
        XCTAssertTrue(surfaced, "the keyed path must surface the identity-changed message")
        XCTAssertFalse(
            failures.contains { $0.isSessionRefused },
            "the generic transport error must not stand in for an identity problem"
        )
        XCTAssertTrue(imposter.sessionPuts.isEmpty, "zero request bytes may reach the imposter")
        XCTAssertNotNil(store.sharedKey(for: id), "an imposter must not cost the stored pairing")
        XCTAssertNil(manager.retry[id], "a user-initiated failure never arms the curve")

        // SILENT keyed retry (auto paths): still no banner — and, unlike a
        // plain outage, NO armed backoff retry either: the row parks until
        // the user acts (android parity, retry = false).
        let messagesBefore = failures.count
        manager.connect(to: imposterServer, intent: .autoReconnect)
        XCTAssertEqual(manager.get(id)?.state, .linking, "connect flips to linking synchronously")
        let parked = await waitUntil { self.manager.get(id)?.state == .idle }
        XCTAssertTrue(parked, "the silent attempt must abort back to idle")
        XCTAssertEqual(failures.count, messagesBefore, "silent intents stay silent")
        XCTAssertNil(manager.retry[id], "an identity mismatch must not enter the backoff curve")
        XCTAssertNil(manager.retryTasks[id], "no one-shot retry may be armed against an imposter")
        XCTAssertFalse(manager.staleSatelliteIds.contains(id), "no 'Needs pairing' for an imposter")
    }

    // MARK: - Pair-time protocol-version 409

    func testPairTimeVersionRejectionBelowTheSatellitesFloorNamesTheApp() async {
        let id = server.id
        satellite.protocolRange = 4 ... 5

        manager.pairWithPin(server, pin: satellite.operatorPin)

        let surfaced = await waitUntil {
            self.failures.contains(.dishUpdateRequired)
        }
        XCTAssertTrue(surfaced, "a pair-time 409 below the satellite's floor must say the app needs updating")
        XCTAssertEqual(manager.get(id)?.protocolCompat, .dishUpdateRequired)
        XCTAssertNil(store.sharedKey(for: id), "a 409'd pair must not mint trust")
        XCTAssertNil(satellite.pairingKeyHex)
        XCTAssertTrue(satellite.sessionPuts.isEmpty, "no session PUT may follow a rejected pair")
        XCTAssertEqual(manager.get(id)?.state, .idle)
    }
}
