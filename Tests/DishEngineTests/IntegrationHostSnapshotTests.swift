// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// A support report asks each live satellite of 2.3.0 or later for its own
// view of the connection, over the session routes' proof, against the
// FakeSatellite: the document, a connection it does not know, a refused
// proof and a host that never answers; an older satellite, by its probe's
// version, is never asked. Asking changes nothing on the link. The client's own
// view of the session rides beside it: the slot as asked and answered, and
// every message counted by kind.

import Combine
import DishCore
import XCTest
@testable import DishEngine

@MainActor
final class IntegrationHostSnapshotTests: XCTestCase {

    private var satellite: FakeSatellite!
    private var ports: FakeSatellite.Ports!
    private var defaults: UserDefaults!
    private var defaultsName: String!
    private var store: ConnectionStore!
    private var manager: WifiConnectionManager!

    private let keyHex = String(repeating: "1f", count: 32)
    private static let document = #"{"format":"satellite-connection-diagnostics.v1","satellite":{"version":"2.3.0"}}"#

    override func setUpWithError() throws {
        try super.setUpWithError()
        satellite = try FakeSatellite()
        ports = try satellite.start()
        try satellite.requireHTTPSTransport()
        defaultsName = "dish.test.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsName)
        store = ConnectionStore(defaults: defaults, keyStore: InMemoryKeyStore())
        manager = WifiConnectionManager(store: store)
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

    private func waitUntil(timeout: TimeInterval = 8, _ predicate: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return predicate()
    }

    @discardableResult
    private func connectAndAwaitLive(version: String = "2.3.0") async throws -> WifiConnection {
        satellite.serverVersion = version
        let conn = WifiConnection(id: server.id, server: server)
        manager.register(conn)
        conn.attachSlot("pad", controllerType: 0, capabilities: .none)
        manager.connect(to: server)
        let live = await waitUntil { self.manager.get(self.server.id)?.state == .live }
        XCTAssertTrue(live, "keyed connect must reach .live")
        XCTAssertTrue(satellite.awaitHeartbeats(atLeast: 1), "reply path must be learned")
        return try XCTUnwrap(manager.get(server.id))
    }

    func testASatelliteWithTheRouteGivesItsOwnDocument() async throws {
        try await connectAndAwaitLive()
        satellite.connectionDiagnostics = Self.document
        let verdicts = await manager.connectionSnapshots()
        guard case let .snapshot(document) = verdicts[server.id] else { return XCTFail("\(verdicts)") }
        XCTAssertEqual(document["satellite"]?["version"], .string("2.3.0"))
        XCTAssertEqual(satellite.diagnosticsGets, [satellite.connectionId])
    }

    func testASatelliteOlderThanTheRouteIsNeverAsked() async throws {
        try await connectAndAwaitLive(version: "2.2.0")
        satellite.connectionDiagnostics = Self.document
        let verdicts = await manager.connectionSnapshots()
        XCTAssertEqual(verdicts[server.id], .failed(.olderSatellite))
        XCTAssertEqual(satellite.diagnosticsGets, [], "the version decides, not a 404")
    }

    func testANotFoundFromASatelliteWithTheRouteIsAnUnknownConnection() async throws {
        try await connectAndAwaitLive()
        let verdicts = await manager.connectionSnapshots()
        XCTAssertEqual(verdicts[server.id], .failed(.unknownConnection))
        XCTAssertEqual(satellite.diagnosticsGets, [satellite.connectionId])
    }

    func testARefusedProofIsAFactForTheFileAndTheKeyStays() async throws {
        let conn = try await connectAndAwaitLive()
        satellite.forced401Code = "BAD_PROOF"
        let verdicts = await manager.connectionSnapshots()
        satellite.forced401Code = nil
        XCTAssertEqual(verdicts[server.id], .failed(.unauthorized))
        XCTAssertNotNil(store.sharedKey(for: server.id), "a report never drops the pairing")
        XCTAssertTrue(conn.hasLiveSession)
    }

    func testAHostThatNeverAnswersTimesOutWithinTheWindow() async throws {
        try await connectAndAwaitLive()
        satellite.stallConnectionDiagnostics = true
        let started = Date()
        let verdicts = await manager.connectionSnapshots(timeout: 0.5)
        XCTAssertEqual(verdicts[server.id], .failed(.timeout))
        XCTAssertLessThan(Date().timeIntervalSince(started), 4)
    }

    func testAHostWithNoLiveLinkIsNotAsked() async {
        manager.register(WifiConnection(id: server.id, server: server))
        let verdicts = await manager.connectionSnapshots()
        XCTAssertEqual(verdicts, [:])
        XCTAssertEqual(satellite.diagnosticsGets, [])
    }

    func testTheSessionCarriesTheSlotAsAskedAndAsAnswered() async throws {
        try await connectAndAwaitLive()
        let session = try XCTUnwrap(manager.sessionFacts(server.id, records: ["pad": "microsoft-xbox-one"]))
        let slot = try XCTUnwrap(session.slots.first)
        XCTAssertEqual(slot.index, 0)
        XCTAssertEqual(slot.record, "microsoft-xbox-one")
        XCTAssertEqual(slot.result, "ok")
        XCTAssertEqual(slot.backend, "fake")
        XCTAssertEqual(slot.requestedType, slot.appliedType)
    }

    func testTheSessionCountsEveryMessageByKind() async throws {
        let conn = try await connectAndAwaitLive()
        let client = try XCTUnwrap(conn.client)
        client.sendReport(controllerIndex: 0, report: GamepadReport(buttons: 1))
        client.sendReport(controllerIndex: 0, report: GamepadReport(buttons: 2))
        let acked = await waitUntil { (client.tally.counts().received[.heartbeatAck] ?? 0) >= 1 }
        XCTAssertTrue(acked, "the ack must be counted")
        let counts = try XCTUnwrap(manager.sessionFacts(server.id, records: [:])?.counts)
        XCTAssertEqual(counts.sent[.input], 2)
        XCTAssertGreaterThanOrEqual(counts.sent[.heartbeat] ?? 0, 1)
        XCTAssertEqual(counts.received[.rumble], 0)
    }

    func testNoSessionNoSessionFacts() {
        XCTAssertNil(manager.sessionFacts(server.id, records: [:]))
    }

    func testTheStandInIsWhatTheProbeAndTheCatalogSaid() async throws {
        try await connectAndAwaitLive()
        let facts = try XCTUnwrap(manager.capabilitiesFacts(server.id))
        XCTAssertEqual(facts.serverVersion, "2.3.0")
        XCTAssertEqual(facts.protocolVersion, 4)
        XCTAssertEqual(facts.controllerAudio, HostAudioBlock(enabled: false, mic: false, speaker: false, hapticAudio: false))
        XCTAssertEqual(facts.catalogVersion, 2)
    }
}
