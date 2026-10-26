// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// Several pads on one satellite against FakeSatellite: one session carries a
// descriptor per pad on its own controller index, each pad's input rides
// its index on the wire, the satellite's rumble on an index reaches the pad
// holding it, and one pad letting go DELETEs its index alone over the
// per-slot routes while the next pad takes the freed index.

import DishCore
import XCTest
@testable import DishEngine

@MainActor
final class SatellitePadsLiveTests: XCTestCase {

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
        try satellite.requireHTTPSTransport()
        defaultsName = "dish.test.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsName)
        store = ConnectionStore(defaults: defaults, keyStore: InMemoryKeyStore())
        manager = WifiConnectionManager(store: store)
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

    private func connectAndAwaitLive() async -> Bool {
        manager.connect(to: server)
        return await waitUntil { self.manager.get(self.server.id)?.state == .live }
    }

    /// The hot path's table as the app builds it, over the pads `conn` carries.
    private func routes(for conn: WifiConnection) -> RoutingTable {
        let table = RoutingTable()
        let bindings = Dictionary(uniqueKeysWithValues: conn.boundSlotIds.map { ($0, server.id) })
        table.set(routeSnapshot(bindings: bindings, pool: [server.id: conn], flags: [:], global: ForwardingFlags()))
        return table
    }

    private func inputFrames() -> [(ctrlIdx: UInt8, report: Data)] {
        satellite.frames.compactMap { frame in
            guard case let .input(ctrlIdx, report) = frame.detail else { return nil }
            return (ctrlIdx, report)
        }
    }

    func testTwoPadsRideOneSessionWithTheirOwnDescriptorsAndInputStreams() async throws {
        let conn = WifiConnection(id: server.id, server: server)
        manager.register(conn)
        manager.typeOverrides.setType(1, for: SlotKey(connectionId: server.id, slotId: "slot-b"))
        conn.attachSlot("slot-a", controllerType: 0, capabilities: ControllerCapabilities(hasMotion: true))
        conn.attachSlot("slot-b", controllerType: 0, capabilities: ControllerCapabilities(hasRumble: true))
        let live = await connectAndAwaitLive()
        XCTAssertTrue(live)

        let put = try XCTUnwrap(satellite.sessionPuts.first)
        let controllers = try XCTUnwrap(put["controllers"] as? [[String: Any]])
        XCTAssertEqual(controllers.compactMap { $0["ctrlIdx"] as? Int }, [0, 1], "one descriptor per pad, in index order")
        XCTAssertEqual(controllers.compactMap { $0["type"] as? Int }, [0, 1], "each pad emulated as its own pick")
        XCTAssertEqual(satellite.appliedControllers.count, 2)
        XCTAssertTrue(conn.isSlotApplied("slot-a") && conn.isSlotApplied("slot-b"))

        let table = routes(for: conn)
        table.get("slot-a")?.sink.sendReport(GamepadReport(buttons: 0x1000, lt: 1, rt: 0, lx: 0, ly: 0, rx: 0, ry: 0))
        table.get("slot-b")?.sink.sendReport(GamepadReport(buttons: 0x2000, lt: 2, rt: 0, lx: 0, ly: 0, rx: 0, ry: 0))
        XCTAssertTrue(satellite.awaitFrameCount(opcode: FakeSatelliteOpcode.input, atLeast: 2))
        let byIndex = Dictionary(uniqueKeysWithValues: inputFrames().map { ($0.ctrlIdx, $0.report) })
        XCTAssertEqual(byIndex[0].map { Array($0.prefix(3)) }, [0x00, 0x10, 0x01], "slot-a's report on index 0")
        XCTAssertEqual(byIndex[1].map { Array($0.prefix(3)) }, [0x00, 0x20, 0x02], "slot-b's report on index 1")
    }

    func testRumbleOnAnIndexReachesThePadHoldingIt() async throws {
        let conn = WifiConnection(id: server.id, server: server)
        manager.register(conn)
        conn.attachSlot("slot-a", controllerType: 0, capabilities: ControllerCapabilities(hasRumble: true))
        conn.attachSlot("slot-b", controllerType: 0, capabilities: ControllerCapabilities(hasRumble: true))
        let recorder = FeedbackRecorder()
        let router = ReturnPathRouter(actuators: recorder.actuators, gate: ForwardingGate(), table: routes(for: conn))
        router.wire([server.id: conn])
        let live = await connectAndAwaitLive()
        XCTAssertTrue(live)
        XCTAssertTrue(satellite.awaitHeartbeats(atLeast: 1), "the reply path is learned from the first uplink frame")

        XCTAssertTrue(satellite.injectRumble(ctrlIdx: 1, strong: 0xFFFF, weak: 0, durationMs: 500))
        let first = await waitUntil { recorder.rumbled == ["slot-b"] }
        XCTAssertTrue(first, "index 1's rumble drives the pad on index 1")
        XCTAssertTrue(satellite.injectRumble(ctrlIdx: 0, strong: 0, weak: 0xFFFF, durationMs: 500))
        let second = await waitUntil { recorder.rumbled == ["slot-b", "slot-a"] }
        XCTAssertTrue(second)
        XCTAssertTrue(satellite.injectRumble(ctrlIdx: 3, strong: 1, weak: 1, durationMs: 500))
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(recorder.rumbled.count, 2, "an index no pad holds rumbles nothing")
    }

    func testDetachingOnePadDeletesItsIndexAloneAndTheNextTakesIt() async {
        let conn = WifiConnection(id: server.id, server: server)
        manager.register(conn)
        conn.attachSlot("slot-a", controllerType: 0, capabilities: .none)
        conn.attachSlot("slot-b", controllerType: 0, capabilities: .none)
        let live = await connectAndAwaitLive()
        XCTAssertTrue(live)

        conn.detachSlot("slot-a")
        let removed = await waitUntil { self.satellite.appliedControllers.compactMap { $0["ctrlIdx"] as? Int } == [1] }
        XCTAssertTrue(removed, "the DELETE named index 0 alone")
        conn.attachSlot("slot-c", controllerType: 0, capabilities: .none)
        let reused = await waitUntil { self.satellite.appliedControllers.compactMap { $0["ctrlIdx"] as? Int } == [0, 1] }
        XCTAssertTrue(reused, "the freed index is PUT for the next pad")
        XCTAssertEqual(conn.controllerIndex(of: "slot-c"), 0)
        XCTAssertEqual(satellite.sessionPuts.count, 1, "the per-slot routes, never a session re-PUT")
    }
}

/// The satellite's feedback as the pads would feel it, recorded by slot.
@MainActor
private final class FeedbackRecorder {
    private(set) var rumbled: [String] = []

    var actuators: SatelliteFeedbackActuators {
        SatelliteFeedbackActuators(
            rumble: { [weak self] deviceId, _ in self?.rumbled.append(deviceId) },
            lightbar: { _, _ in },
            triggerEffects: { _, _ in },
            playerLeds: { _, _ in }
        )
    }
}
