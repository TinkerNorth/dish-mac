// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// Manager-level control-plane flows against FakeSatellite: keyed connect →
// declarative PUT → live session, terminal-401 key drop (row survives,
// stale marker set), terminal-409 UX, forget → self-unpair ordering, and
// the path-B approval loop end-to-end (G5/G6/G8/G11/G16/G17 wiring).

import Combine
import XCTest
@testable import Dish

@MainActor
final class WifiConnectionManagerControlPlaneTests: XCTestCase {

    private var satellite: FakeSatellite!
    private var ports: FakeSatellite.Ports!
    private var defaults: UserDefaults!
    private var defaultsName: String!
    private var keyStore: InMemoryKeyStore!
    private var store: ConnectionStore!
    private var manager: WifiConnectionManager!
    private var events: [ConnectionEvent] = []
    private var bag = Set<AnyCancellable>()
    private var savedPollInterval = 0
    private var savedPollTimeout = 0

    override func setUpWithError() throws {
        try super.setUpWithError()
        satellite = try FakeSatellite()
        ports = try satellite.start()
        defaultsName = "dish.test.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsName)
        keyStore = InMemoryKeyStore()
        store = ConnectionStore(defaults: defaults, keyStore: keyStore)
        manager = WifiConnectionManager(store: store)
        events = []
        manager.events
            .sink { [weak self] event in self?.events.append(event) }
            .store(in: &bag)
        savedPollInterval = WifiConnectionManager.approvalPollIntervalMs
        savedPollTimeout = WifiConnectionManager.approvalTimeoutMs
    }

    override func tearDown() {
        WifiConnectionManager.approvalPollIntervalMs = savedPollInterval
        WifiConnectionManager.approvalTimeoutMs = savedPollTimeout
        for id in manager.connections.keys {
            manager.disconnect(id: id)
        }
        satellite.stop()
        defaults.removePersistentDomain(forName: defaultsName)
        bag.removeAll()
        super.tearDown()
    }

    /// The satellite as discovery would present it — machineId included, so
    /// the pool/store key is the contract's `mid:` form.
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

    private var serverId: String {
        server.id
    }

    /// Plant matching trust material on both ends (skips the PIN dance).
    private func prePair(keyHex: String = String(repeating: "1f", count: 32)) {
        satellite.pairingKeyHex = keyHex
        store.setSharedKey(keyHex, for: serverId)
    }

    private func waitUntil(
        timeout: TimeInterval = 5,
        _ predicate: () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return predicate()
    }

    private var errorMessages: [String] {
        events.compactMap {
            if case let .error(message) = $0 { return message }
            return nil
        }
    }

    // MARK: - Keyed connect → PUT → live

    func testConnectWithSavedKeyEstablishesLiveSession() async throws {
        prePair()
        manager.connect(to: server)
        let live = await waitUntil { self.manager.get(self.serverId)?.state == .live }
        XCTAssertTrue(live, "keyed connect must reach .live via the session PUT")

        XCTAssertEqual(satellite.sessionPuts.count, 1)
        let put = try XCTUnwrap(satellite.sessionPuts.first)
        XCTAssertEqual(put["deviceId"] as? String, store.getOrCreateDeviceId())
        XCTAssertEqual(put["protocolVersion"] as? Int, 1)

        // Success remembers the satellite under its stable mid: identity.
        let row = store.remembered().first { $0.id == serverId }
        XCTAssertNotNil(row)
        XCTAssertEqual(row?.machineId, satellite.machineId)
        XCTAssertTrue(serverId.hasPrefix("mid:"))
        XCTAssertFalse(manager.staleSatelliteIds.contains(serverId))
    }

    // MARK: - Terminal 401 (G6)

    func testTerminalAuthDropsOnlyKeyAndParksRowStale() async {
        // The satellite holds a DIFFERENT key: our proof fails → 401 BAD_PROOF.
        satellite.pairingKeyHex = String(repeating: "2e", count: 32)
        store.setSharedKey(String(repeating: "1f", count: 32), for: serverId)
        store.remember(server)

        manager.connect(to: server) // user-initiated by default

        let dropped = await waitUntil { self.store.sharedKey(for: self.serverId) == nil }
        XCTAssertTrue(dropped, "terminal 401 must drop the pairing key")
        XCTAssertTrue(manager.staleSatelliteIds.contains(serverId), "row parks on Needs pairing")
        XCTAssertEqual(
            store.remembered().first { $0.id == self.serverId }?.id,
            serverId,
            "the remembered row must SURVIVE a terminal 401"
        )
        let surfaced = await waitUntil {
            self.errorMessages.contains(WifiConnectionManager.repairNeededMessage)
        }
        XCTAssertTrue(surfaced, "user-initiated terminal auth is loud")
        XCTAssertEqual(manager.get(serverId)?.state, .idle)
    }

    func testSilentIntentTerminalAuthIsQuiet() async {
        satellite.pairingKeyHex = String(repeating: "2e", count: 32)
        store.setSharedKey(String(repeating: "1f", count: 32), for: serverId)
        store.remember(server)

        manager.connect(to: server, intent: .autoReconnect)

        let dropped = await waitUntil { self.store.sharedKey(for: self.serverId) == nil }
        XCTAssertTrue(dropped)
        XCTAssertTrue(manager.staleSatelliteIds.contains(serverId))
        XCTAssertFalse(
            errorMessages.contains(WifiConnectionManager.repairNeededMessage),
            "background intents never banner"
        )
    }

    // MARK: - Terminal 409 (G5)

    func testVersionMismatchSurfacesTerminalMessageAndKeepsKey() async {
        prePair()
        satellite.protocolVersionReject = true

        manager.connect(to: server)

        let surfaced = await waitUntil {
            self.errorMessages.contains(WifiConnectionManager.protocolMismatchMessage)
        }
        XCTAssertTrue(surfaced)
        XCTAssertNotNil(store.sharedKey(for: serverId), "version skew is not trust loss")
        XCTAssertFalse(manager.staleSatelliteIds.contains(serverId))
        XCTAssertEqual(manager.get(serverId)?.state, .idle)
    }

    // MARK: - Forget → self-unpair (G16)

    func testForgetSelfUnpairsServerSideBeforeDroppingKey() async {
        prePair()
        store.remember(server)

        manager.forget(id: serverId)

        let unpaired = await waitUntil { self.satellite.unpairCalls.count == 1 }
        XCTAssertTrue(unpaired, "forget must DELETE /api/pair (best-effort self-unpair)")
        XCTAssertEqual(satellite.unpairCalls.first, store.getOrCreateDeviceId())
        XCTAssertNil(satellite.pairingKeyHex, "satellite drops the trust row")
        XCTAssertNil(store.sharedKey(for: serverId))
        XCTAssertTrue(store.remembered().isEmpty)
        XCTAssertNil(manager.get(serverId))
    }

    // MARK: - Path B end-to-end (G16)

    func testClientPinApprovalFlowLandsKeyAndSession() async {
        WifiConnectionManager.approvalPollIntervalMs = 50
        satellite.pairingKeyHex = nil

        manager.pairWithClientPin(server, clientPin: "1234")

        let submitted = await waitUntil { self.satellite.lastClientPin == "1234" }
        XCTAssertTrue(submitted)
        satellite.approveClientPin()

        let keyed = await waitUntil { self.store.sharedKey(for: self.serverId) != nil }
        XCTAssertTrue(keyed, "approval poll must land the staged key")
        XCTAssertEqual(store.sharedKey(for: serverId), satellite.pairingKeyHex)
        let opened = await waitUntil { !self.satellite.sessionPuts.isEmpty }
        XCTAssertTrue(opened, "approval flows straight into the session PUT")
    }

    func testClientPinDeclineSurfacesDeclinedMessage() async {
        WifiConnectionManager.approvalPollIntervalMs = 50
        satellite.pairingKeyHex = nil

        manager.pairWithClientPin(server, clientPin: "9911")
        let submitted = await waitUntil { self.satellite.lastClientPin == "9911" }
        XCTAssertTrue(submitted)
        satellite.denyClientPin()

        let declined = await waitUntil {
            self.errorMessages.contains(WifiConnectionManager.approvalDeclinedMessage)
        }
        XCTAssertTrue(declined)
        XCTAssertNil(store.sharedKey(for: serverId))
        XCTAssertEqual(manager.get(serverId)?.state, .idle)
    }
}
