// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// The Emulate pick end to end against the fake satellite: a first contact
// already emulates the pad as itself, a pick re-sends the descriptor over
// the per-slot route with the new type, clearing it returns to the family,
// the satellite's motion word lands in the store, and a forgotten satellite
// takes its picks with it.

import Combine
import DishCore
import XCTest
@testable import DishEngine

@MainActor
final class EmulationLiveTests: XCTestCase {

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

    private var key: SlotKey {
        SlotKey(connectionId: server.id, slotId: "slot-a")
    }

    private var appliedType: Int? {
        satellite.appliedControllers.first?["type"] as? Int
    }

    private func waitUntil(timeout: TimeInterval = 8, _ predicate: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return predicate()
    }

    /// A DualSense bound through the hub before any session, as the UI does.
    private func bindDualSenseAndGoLive() async throws -> WifiConnection {
        let conn = WifiConnection(id: server.id, server: server)
        manager.register(conn)
        hub.bind(
            slotId: "slot-a",
            connectionId: server.id,
            capabilities: ControllerCapabilities(hasMotion: true, hasRumble: true),
            family: .dualSense
        )
        manager.connect(to: server)
        let live = await waitUntil { conn.state == .live && self.appliedType != nil }
        XCTAssertTrue(live, "the connect must reach .live with the slot applied")
        return conn
    }

    func testAFirstContactEmulatesThePadAsItself() async throws {
        _ = try await bindDualSenseAndGoLive()
        XCTAssertEqual(appliedType, 2, "the catalog is read before the first PUT, so the DualSense type rides it")
        XCTAssertEqual(satellite.sessionPuts.count, 1)
    }

    func testAPickReSendsTheDescriptorAndClearingItReturnsToTheFamily() async throws {
        _ = try await bindDualSenseAndGoLive()
        hub.setEmulatedType(slotId: "slot-a", type: 1, family: .dualSense)
        let picked = await waitUntil { self.appliedType == 1 }
        XCTAssertTrue(picked, "the per-slot route carries the new type")
        XCTAssertEqual(satellite.sessionPuts.count, 1, "the session is not re-PUT")
        XCTAssertEqual(manager.typeOverrides.typeFor(key), 1)

        hub.setEmulatedType(slotId: "slot-a", type: nil, family: .dualSense)
        let restored = await waitUntil { self.appliedType == 2 }
        XCTAssertTrue(restored, "no pick means the family's own type again")
        XCTAssertNil(manager.typeOverrides.typeFor(key))
    }

    func testTheSamePickTwiceSendsNothing() async throws {
        _ = try await bindDualSenseAndGoLive()
        hub.setEmulatedType(slotId: "slot-a", type: 2, family: .dualSense)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(appliedType, 2)
        XCTAssertEqual(satellite.sessionPuts.count, 1)
        XCTAssertFalse(manager.get(server.id)?.isRegisteringController ?? true)
    }

    func testTheMotionWordLandsWithTheApplyAndLeavesWithTheBinding() async throws {
        _ = try await bindDualSenseAndGoLive()
        let recorded = await waitUntil { self.manager.motionStatus.statusFor(self.key) != nil }
        XCTAssertTrue(recorded)
        XCTAssertEqual(manager.motionStatus.statusFor(key), MotionBackendStatus(sinkSupportedForType: true, backendOk: true))
        hub.unbind(slotId: "slot-a")
        XCTAssertNil(manager.motionStatus.statusFor(key), "an unbound slot has no motion word")
    }

    func testForgettingTheSatelliteDropsItsPicksAndWords() async throws {
        _ = try await bindDualSenseAndGoLive()
        hub.setEmulatedType(slotId: "slot-a", type: 1, family: .dualSense)
        _ = await waitUntil { self.appliedType == 1 }
        manager.forget(id: server.id)
        XCTAssertEqual(manager.typeOverrides.state, [:])
        XCTAssertEqual(manager.motionStatus.state, [:])
    }
}
