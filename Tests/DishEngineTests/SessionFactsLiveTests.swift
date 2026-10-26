// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// The Diagnostics facts against the fake satellite: a resting row, a live
// session's negotiation, epoch, bitmap, backend, heartbeats and grant, the
// bound slot's side of the wire, and the source that composes them.

import Combine
import DishCore
import XCTest
@testable import DishEngine

@MainActor
final class SessionFactsLiveTests: XCTestCase {

    private var satellite: FakeSatellite!
    private var ports: FakeSatellite.Ports!
    private var defaults: UserDefaults!
    private var defaultsName: String!
    private var store: ConnectionStore!
    private var manager: WifiConnectionManager!
    private var hub: ConnectionHub!

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

    private func waitUntil(timeout: TimeInterval = 8, _ predicate: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return predicate()
    }

    private func bindAndGoLive() async throws -> WifiConnection {
        let conn = WifiConnection(id: server.id, server: server)
        manager.register(conn)
        hub.bind(
            slotId: "slot-a",
            connectionId: server.id,
            capabilities: ControllerCapabilities(hasMotion: true, hasRumble: true),
            family: .dualSense
        )
        manager.connect(to: server)
        let acked = await waitUntil { conn.state == .live && conn.lastHeartbeatAck != nil }
        XCTAssertTrue(acked, "the session must go live and hear its first enriched ack")
        return conn
    }

    func testARestingConnectionReadsAsNoSession() {
        let conn = WifiConnection(id: server.id, server: server)
        let facts = hostSessionFacts(of: conn)
        XCTAssertFalse(facts.live)
        XCTAssertEqual(facts.appliedEpoch, -1)
        XCTAssertNil(facts.hostEpoch)
        XCTAssertNil(facts.hostBitmap)
        XCTAssertNil(facts.backendAvailable)
        XCTAssertEqual(facts.missedAcks, 0)
        XCTAssertEqual(facts.latency.samples, 0)
        XCTAssertNil(slotWireFacts(of: conn, slotId: "slot-a"), "no descriptor without a bound slot")
        XCTAssertEqual(HostSessionFacts.resting(id: "x").offeredProtocol, ProtocolConstants.protocolVersion)
    }

    func testALiveSessionTellsItsWholeStory() async throws {
        let conn = try await bindAndGoLive()
        let facts = hostSessionFacts(of: conn)
        XCTAssertTrue(facts.live)
        XCTAssertEqual(facts.settledProtocol, 3)
        XCTAssertEqual(facts.offeredProtocol, 3)
        XCTAssertEqual(facts.compat, .current)
        XCTAssertEqual(epochAgreement(hostEpoch: facts.hostEpoch, appliedEpoch: facts.appliedEpoch), .inStep)
        XCTAssertEqual(facts.confirmedBitmap, 1)
        XCTAssertEqual(bitmapAgreement(hostBitmap: facts.hostBitmap, confirmedBitmap: facts.confirmedBitmap), .inStep)
        XCTAssertEqual(hostBackendOf(facts.backendAvailable), .available)
        XCTAssertEqual(facts.activeControllers, 1)
        XCTAssertEqual(facts.missedAcks, 0)
        XCTAssertFalse(facts.mouseControlGranted, "the fake grants no mouse control")
        XCTAssertEqual(facts.latency.capacity, LatencyWindow.capacity)
    }

    func testTheBoundSlotsWireFactsReadTheDescriptorAndTheAck() async throws {
        let conn = try await bindAndGoLive()
        let wire = try XCTUnwrap(slotWireFacts(of: conn, slotId: "slot-a"))
        XCTAssertEqual(wire.controllerIndex, 0)
        XCTAssertEqual(wire.type, 2, "the DualSense type from the catalog")
        XCTAssertEqual(advertisedCaps(wire.caps), [.analogTriggers, .rumble, .motion])
        XCTAssertEqual(wire.touchpad, .off, "no touchpad on this pad")
        XCTAssertTrue(wire.confirmed)
        XCTAssertEqual(wire.streaming, .yes)
    }

    func testTheSourceComposesHostsAndPadsAndTicksWhileStarted() async throws {
        _ = try await bindAndGoLive()
        let source = DiagnosticsSource(wifi: manager, hub: hub)
        var slots: [ControllerSlot] = []
        source.useSlots { slots }
        source
            .useAudio { slotId in
                PadAudioDiagnostics(route: nil, state: nil, counters: AudioCounters(micSent: slotId == "slot-a" ? 1 : 0))
            }
        source.refresh()
        XCTAssertEqual(source.state.hosts.count, 1)
        XCTAssertEqual(source.state.hosts.first?.summary.live, .connected)
        XCTAssertTrue(source.state.hosts.first?.facts.live ?? false)
        XCTAssertEqual(source.state.hosts.first?.facts.audio, HostAudioVerdict.none, "the fake grants no controller audio by default")
        XCTAssertEqual(source.state.pads, [])

        var slot = ControllerSlot(id: "slot-a", name: "DualSense")
        slot.boundConnectionId = server.id
        slots = [slot]
        source.start()
        let ticked = await waitUntil(timeout: 3) { source.state.pads.first?.wire?.confirmed == true }
        XCTAssertTrue(ticked, "the tick re-reads the slot list and the wire")
        XCTAssertEqual(source.state.pads.first?.audio?.counters?.micSent, 1, "and each pad's audio by its id")
        source.stop()
        slots = []
        try await Task.sleep(nanoseconds: 1_200_000_000)
        XCTAssertEqual(source.state.pads.count, 1, "a stopped source no longer ticks")
    }

    func testARememberedSatelliteWithoutAConnectionRestsInTheSnapshot() async {
        store.remember(server)
        manager.markStale(server.id)
        let listed = await waitUntil { self.hub.connections.first?.id == self.server.id }
        XCTAssertTrue(listed, "the remembered row reaches the hub")
        let source = DiagnosticsSource(wifi: manager, hub: hub)
        source.refresh()
        let host = source.state.hosts.first
        XCTAssertEqual(host?.summary.id, server.id)
        XCTAssertEqual(host?.facts, HostSessionFacts.resting(id: server.id))
    }
}
