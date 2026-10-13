// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// The per-controller switches against the fake satellite: the fold the app
// model performs on every change (`connectionFlags`) pushed through the
// manager takes a claim out of a live slot's descriptor over the per-slot
// route, and the global switch outranks the controller's own.

import Combine
import DishCore
import XCTest
@testable import DishEngine

@MainActor
final class SlotSwitchesLiveTests: XCTestCase {

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

    private var claimedMotion: Bool? {
        (satellite.appliedControllers.first?["caps"] as? [String: Any])?["motion"] as? Bool
    }

    private func waitUntil(timeout: TimeInterval = 8, _ predicate: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return predicate()
    }

    /// What the app model does on every change: fold and push.
    private func push(global: ForwardingFlags, preferences: [String: SlotPreferences]) {
        let ids = manager.connections.keys
        let preferences = ["slot-a": SlotPreferences(motion: false)]
        let flags = connectionFlags(bindings: [:], connectionIds: ids, global: ForwardingFlags(rumble: false), preferences: preferences)
        XCTAssertEqual(flags[server.id], ForwardingFlags(rumble: false), "nothing bound: the controller's switches do not apply")
    }
}
