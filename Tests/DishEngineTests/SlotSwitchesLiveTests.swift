// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// The per-controller switches against the fake satellite: the fold the app
// model performs on every change (`slotFlags`) pushed into the connection
// takes a claim out of that pad's descriptor alone over its per-slot route,
// with a second pad on the same satellite untouched, and the global switch
// outranks the controller's own.

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

    private func claimedMotion(ctrlIdx: Int) -> Bool? {
        let applied = satellite.appliedControllers.first { $0["ctrlIdx"] as? Int == ctrlIdx }
        return (applied?["caps"] as? [String: Any])?["motion"] as? Bool
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
        let flags = slotFlags(bindings: hub.bindings, global: global, preferences: preferences)
        for conn in manager.connections.values {
            conn.setForwardingFlags(global)
            conn.setSlotFlags(flags)
        }
    }

    private func bindTwoPadsAndGoLive() async -> Bool {
        let conn = WifiConnection(id: server.id, server: server)
        manager.register(conn)
        let motion = ControllerCapabilities(hasMotion: true)
        hub.bind(slotId: "slot-a", connectionId: server.id, capabilities: motion, family: .dualSense)
        hub.bind(slotId: "slot-b", connectionId: server.id, capabilities: motion, family: .dualSense)
        manager.connect(to: server)
        return await waitUntil { conn.state == .live && self.satellite.appliedControllers.count == 2 }
    }

    func testOnePadsSwitchTakesItsClaimOutAndTheOtherPadKeepsIts() async {
        let live = await bindTwoPadsAndGoLive()
        XCTAssertTrue(live)
        XCTAssertEqual(claimedMotion(ctrlIdx: 0), true)
        XCTAssertEqual(claimedMotion(ctrlIdx: 1), true)
        let putsBefore = satellite.sessionPuts.count

        push(global: ForwardingFlags(), preferences: ["slot-a": SlotPreferences(motion: false)])

        let withdrawn = await waitUntil { self.claimedMotion(ctrlIdx: 0) == false }
        XCTAssertTrue(withdrawn, "slot-a's descriptor no longer claims motion")
        XCTAssertEqual(claimedMotion(ctrlIdx: 1), true, "slot-b's descriptor is untouched")
        XCTAssertEqual(satellite.sessionPuts.count, putsBefore, "the per-slot route, not a session re-PUT")
    }

    func testTheGlobalSwitchOutranksEveryPadsOwn() async {
        let live = await bindTwoPadsAndGoLive()
        XCTAssertTrue(live)
        push(global: ForwardingFlags(motion: false), preferences: ["slot-a": SlotPreferences(motion: true)])
        let withdrawn = await waitUntil { self.claimedMotion(ctrlIdx: 0) == false && self.claimedMotion(ctrlIdx: 1) == false }
        XCTAssertTrue(withdrawn)
    }
}
