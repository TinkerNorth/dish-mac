// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// Contract §Versioning end to end against the fake satellite: the offer, the
// 409 re-offer, the settled version keying the 0x000C frame, the compat chip
// the row wears, the capabilities probe, the descriptor re-sent whole when a
// switch flips, and the two version-2 return paths reaching the connection.

import Combine
import DishCore
import XCTest
@testable import DishEngine

@MainActor
final class ProtocolNegotiationLiveTests: XCTestCase {

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
        manager = WifiConnectionManager(store: store)
        events = []
        manager.events.sink { [weak self] event in self?.events.append(event) }.store(in: &bag)
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

    private var failures: [ConnectionFailure] {
        events.compactMap {
            switch $0 {
            case let .failure(failure), let .pairingFailed(_, failure): failure
            case .pairingRequired: nil
            }
        }
    }

    /// Plant matching trust material on both ends, skipping the PIN dance.
    private func prePair() {
        let keyHex = String(repeating: "1f", count: 32)
        satellite.pairingKeyHex = keyHex
        store.setSharedKey(keyHex, for: server.id)
    }

    private func waitUntil(timeout: TimeInterval = 8, _ predicate: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return predicate()
    }

    private func connectAndAwaitLive() async throws -> WifiConnection {
        manager.connect(to: server)
        let live = await waitUntil { self.manager.get(self.server.id)?.state == .live }
        XCTAssertTrue(live, "the connect must reach .live: \(failures)")
        return try XCTUnwrap(manager.get(server.id))
    }

    private var offers: [Int] {
        satellite.sessionPuts.compactMap { $0["protocolVersion"] as? Int }
    }

    private let touchpadSample = TouchpadSample(
        finger0: TouchpadFinger(active: true, id: 4, x: 100, y: -100),
        finger1: .none,
        buttonPressed: true
    )

    // MARK: - Settlement keys the frames and the chip

    func testAVersionThreeSatelliteSettlesCurrentAndStreamsThePointerFrame() async throws {
        prePair()
        let conn = try await connectAndAwaitLive()
        XCTAssertEqual(offers, [ProtocolConstants.protocolVersion])
        XCTAssertEqual(conn.settledProtocolVersion, 3)
        XCTAssertEqual(conn.protocolCompat, .current)

        conn.sendTouchpad(sample: touchpadSample, eventTimeMs: 7, controllerIndex: 0)
        let frame = try XCTUnwrap(satellite.awaitFrame(opcode: FakeSatelliteOpcode.touchpad))
        guard case let .pointer(pointer) = frame.detail else {
            return XCTFail("a v3 session streams the 19-byte frame, got \(frame.detail)")
        }
        XCTAssertEqual(pointer.fingerFlags, 0x01)
        XCTAssertEqual(pointer.buttons, ProtocolConstants.pointerButtonLeft, "the click rides the buttons byte")
        XCTAssertEqual(pointer.finger0X, 100)
        XCTAssertEqual(pointer.scrollV, 0)
    }

    func testAVersionOneSatelliteIsReOfferedOneAndStreamsTheSixteenByteFrame() async throws {
        prePair()
        satellite.protocolRange = 1 ... 1
        let conn = try await connectAndAwaitLive()
        XCTAssertEqual(satellite.rejectedOffers, [3])
        XCTAssertEqual(offers, [1], "the 409 lowers the offer to the satellite's ceiling at once")
        XCTAssertEqual(conn.settledProtocolVersion, 1)
        XCTAssertEqual(conn.offeredProtocolVersion, 1, "the lowered offer sticks to the connection")
        XCTAssertEqual(conn.protocolCompat, .satelliteUpdateAvailable, "the soft hint, never an error")
        XCTAssertTrue(failures.isEmpty)

        conn.sendTouchpad(sample: touchpadSample, eventTimeMs: 7, controllerIndex: 0)
        let frame = try XCTUnwrap(satellite.awaitFrame(opcode: FakeSatelliteOpcode.touchpad))
        guard case let .touchpad(touchpad) = frame.detail else {
            return XCTFail("a v1 session streams the 16-byte frame, got \(frame.detail)")
        }
        XCTAssertEqual(touchpad.flags, 0x05, "finger 0 and the click share the flags byte on version 1")
    }

    func testAReconnectKeepsTheLoweredOffer() async throws {
        prePair()
        satellite.protocolRange = 1 ... 1
        let conn = try await connectAndAwaitLive()
        manager.disconnect(id: server.id)
        let idle = await waitUntil { self.manager.get(self.server.id)?.state == .idle }
        XCTAssertTrue(idle)
        _ = try await connectAndAwaitLive()
        XCTAssertEqual(satellite.rejectedOffers, [3], "the second connect never repeats the rejected offer")
        XCTAssertEqual(offers, [1, 1])
        XCTAssertEqual(conn.settledProtocolVersion, 1)
    }

    func testAFloorAboveOursSetsTheRedChipAndKeepsTheKey() async {
        prePair()
        satellite.protocolRange = 4 ... 5
        manager.connect(to: server)
        let surfaced = await waitUntil { self.failures.contains(.dishUpdateRequired) }
        XCTAssertTrue(surfaced)
        XCTAssertEqual(manager.get(server.id)?.protocolCompat, .dishUpdateRequired)
        XCTAssertNotNil(store.sharedKey(for: server.id))
        XCTAssertEqual(satellite.rejectedOffers, [3], "a disjoint range is not re-offered")
        XCTAssertEqual(offers, [])
    }

    func testAnUnreadableRangeBlamesNeitherEnd() async {
        prePair()
        satellite.protocolRange = 0 ... 0
        manager.connect(to: server)
        let surfaced = await waitUntil { self.failures.contains(.protocolMismatch) }
        XCTAssertTrue(surfaced)
        XCTAssertEqual(manager.get(server.id)?.protocolCompat, .unknown, "the chip must not guess")
    }

    // MARK: - Pairing negotiates too

    func testPairingWithAnOlderSatelliteReOffersAndPairs() async {
        satellite.protocolRange = 1 ... 1
        manager.pairWithPin(server, pin: satellite.operatorPin)
        let live = await waitUntil { self.manager.get(self.server.id)?.state == .live }
        XCTAssertTrue(live, "the pair must re-offer 1 and open the session: \(failures)")
        XCTAssertEqual(satellite.settledProtocolVersion, 1)
        XCTAssertEqual(manager.get(server.id)?.protocolCompat, .satelliteUpdateAvailable)
        XCTAssertNotNil(store.sharedKey(for: server.id))
    }

    // MARK: - The probe and the hub

    func testTheCapabilitiesProbeIsCachedAtOpen() async throws {
        prePair()
        _ = try await connectAndAwaitLive()
        let probe = try XCTUnwrap(manager.capabilities[server.id])
        XCTAssertTrue(probe.reachable)
        XCTAssertEqual(probe.protocolVersion, 3)
        XCTAssertTrue(probe.host.catalog.supported)
    }

    func testTheSummaryCarriesTheChip() async throws {
        prePair()
        let hub = ConnectionHub(wifi: manager, store: store)
        satellite.protocolRange = 1 ... 1
        _ = try await connectAndAwaitLive()
        let hinted = await waitUntil { hub.connections.first?.compat == .satelliteUpdateAvailable }
        XCTAssertTrue(hinted, "the row wears the soft hint")
    }

    // MARK: - Honest caps follow the switches

    func testASwitchFlipReSendsTheDescriptorWhole() async throws {
        prePair()
        let conn = WifiConnection(id: server.id, server: server)
        manager.register(conn)
        conn.attachSlot("slot-a", controllerType: 0, capabilities: ControllerCapabilities(hasMotion: true, hasRumble: true))
        _ = try await connectAndAwaitLive()
        let before = try XCTUnwrap(satellite.appliedControllers.first?["caps"] as? [String: Any])
        XCTAssertEqual(before["motion"] as? Bool, true)

        manager.applyForwardingFlags(ForwardingFlags(motion: false))

        let reclaimed = await waitUntil {
            (self.satellite.appliedControllers.first?["caps"] as? [String: Any])?["motion"] as? Bool == false
        }
        XCTAssertTrue(reclaimed, "a switched-off feature is no longer claimed")
        XCTAssertEqual(satellite.sessionPuts.count, 1, "the per-slot route converges; the session is not re-PUT")
    }

    func testTheSameFlagsTwiceSendNothing() async throws {
        prePair()
        let conn = WifiConnection(id: server.id, server: server)
        manager.register(conn)
        conn.attachSlot("slot-a", controllerType: 0, capabilities: ControllerCapabilities(hasMotion: true))
        _ = try await connectAndAwaitLive()
        manager.applyForwardingFlags(ForwardingFlags())
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(satellite.sessionPuts.count, 1)
        XCTAssertFalse(conn.isRegisteringController)
    }

    // MARK: - The version-2 return paths

    func testTriggerEffectsAndPlayerLedsReachTheConnection() async throws {
        prePair()
        let conn = try await connectAndAwaitLive()
        var effects: [TriggerEffectsCommand] = []
        var leds: [PlayerLedsCommand] = []
        conn.setTriggerEffectsHandler { effects.append($0) }
        conn.setPlayerLedsHandler { leds.append($0) }
        XCTAssertTrue(satellite.awaitHeartbeats(atLeast: 1), "the reply path is learned from the first uplink frame")

        let left = [UInt8](repeating: 0x21, count: 11)
        let right = [UInt8](repeating: 0x25, count: 11)
        XCTAssertTrue(satellite.injectTriggerEffects(ctrlIdx: 0, left: left, right: right))
        XCTAssertTrue(satellite.injectPlayerLeds(ctrlIdx: 0, mask: 0b01010))

        let arrived = await waitUntil { effects.count == 1 && leds.count == 1 }
        XCTAssertTrue(arrived)
        XCTAssertEqual(effects.first, TriggerEffectsCommand(controllerIndex: 0, left: left, right: right))
        XCTAssertEqual(leds.first?.playerNumber, 2)
    }
}
