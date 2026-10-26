// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// Mouse mode against the fake satellite: the pick rides the descriptor as
// `touchpadMode: "mouse"` and the session PUT as `hostFeatures.mouseControl`,
// the grant lands on the connection, and a pick flipped mid-session
// converges the whole session through the re-key path without a teardown.

import Combine
import DishCore
import XCTest
@testable import DishEngine

@MainActor
final class MouseModeLiveTests: XCTestCase {

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

    private var appliedTouchpadMode: String? {
        satellite.appliedControllers.first?["touchpadMode"] as? String
    }

    private func requestedMouseControl(inPut index: Int) -> Bool? {
        guard satellite.sessionPuts.count > index else { return nil }
        return (satellite.sessionPuts[index]["hostFeatures"] as? [String: Any])?["mouseControl"] as? Bool
    }

    private func waitUntil(timeout: TimeInterval = 8, _ predicate: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return predicate()
    }

    /// A DualSense with a touchpad, bound before any session, its touchpad
    /// picked as `pick`.
    private func bindAndGoLive(pick: TouchpadPick) async throws -> WifiConnection {
        let conn = WifiConnection(id: server.id, server: server)
        manager.register(conn)
        hub.bind(slotId: "slot-a", connectionId: server.id, capabilities: ControllerCapabilities(hasTouchpad: true), family: .dualSense)
        manager.applyForwardingFlags(ForwardingFlags(touchpadPick: pick), to: server.id)
        manager.connect(to: server)
        let live = await waitUntil { conn.state == .live && self.appliedTouchpadMode != nil }
        XCTAssertTrue(live)
        return conn
    }

    func testTheMousePickRidesTheFirstPutAndTheGrantLands() async throws {
        let conn = try await bindAndGoLive(pick: .mouse)
        XCTAssertTrue(conn.wantsMouseControl)
        XCTAssertEqual(appliedTouchpadMode, "mouse", "the probe is read before the first PUT, so the mouse rung is open")
        XCTAssertEqual(requestedMouseControl(inPut: 0), true)
        XCTAssertTrue(conn.mouseControlGranted)
        XCTAssertEqual(satellite.sessionPuts.count, 1)
    }

    func testThePadPickAsksForNoMouseControl() async throws {
        let conn = try await bindAndGoLive(pick: .pad)
        XCTAssertFalse(conn.wantsMouseControl)
        XCTAssertEqual(appliedTouchpadMode, "ds4")
        XCTAssertEqual(requestedMouseControl(inPut: 0), false)
        XCTAssertFalse(conn.mouseControlGranted)
    }

    func testAPickFlippedMidSessionConvergesTheGrantWithoutATeardown() async throws {
        let conn = try await bindAndGoLive(pick: .pad)
        let client = conn.client
        manager.applyForwardingFlags(ForwardingFlags(touchpadPick: .mouse), to: server.id)
        let granted = await waitUntil { conn.mouseControlGranted }
        XCTAssertTrue(granted, "the per-slot PUT carried the mode and the re-key PUT carried the request")
        XCTAssertEqual(appliedTouchpadMode, "mouse")
        XCTAssertEqual(satellite.sessionPuts.count, 2)
        XCTAssertEqual(requestedMouseControl(inPut: 1), true)
        XCTAssertTrue(conn.client === client, "the same socket: a re-key, not a reconnect")
        XCTAssertEqual(conn.state, .live)

        manager.applyForwardingFlags(ForwardingFlags(touchpadPick: .off), to: server.id)
        let withdrawn = await waitUntil { !conn.mouseControlGranted && self.appliedTouchpadMode == "off" }
        XCTAssertTrue(withdrawn)
        XCTAssertEqual(satellite.sessionPuts.count, 3)
        XCTAssertEqual(requestedMouseControl(inPut: 2), false)
    }

    func testAPickTheHostCannotCarryDeclaresOffButStillAsksForTheMouse() async throws {
        let conn = try await bindAndGoLive(pick: .pad)
        conn.setHostMouseControl(false)
        manager.applyForwardingFlags(ForwardingFlags(touchpadPick: .mouse), to: server.id)
        let declared = await waitUntil { self.appliedTouchpadMode == "off" }
        XCTAssertTrue(declared, "a mouse pick without the host's word declares off, never the pad render")
        XCTAssertTrue(conn.wantsMouseControl, "the request still states the user's desire")
    }
}
