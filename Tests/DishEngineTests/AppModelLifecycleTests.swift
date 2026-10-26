// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Combine
import XCTest
@testable import DishCore
@testable import DishEngine

/// The host's sleep and wake through the composition root: sleep releases
/// what is held and closes the satellite and Moonlight sessions cleanly, wake
/// reopens both and scans again, and a lid that closed on a stream is said
/// once.
@MainActor
final class AppModelLifecycleTests: XCTestCase {

    private var defaults: UserDefaults!
    private var defaultsName: String!
    private var store: ConnectionStore!
    private var willSleep: PassthroughSubject<Void, Never>!
    private var didWake: PassthroughSubject<Void, Never>!
    private var gateway: ScriptedMoonlightGateway!
    private var edges: FakeMoonlightEdges!
    private var moonlight: MoonlightConnectionManager!
    private var clamshell: FakeClamshell!
    private var lan: CountingLan!
    private var model: AppModel!
    private var bag = Set<AnyCancellable>()
    private let host = MoonlightHost(name: "PC", address: "10.0.0.5", uniqueId: "abc")
    private let pad = GameControllerInput.Slot(id: "pad", name: "Xbox", capabilities: .none, battery: nil, family: .xbox)

    override func setUp() {
        super.setUp()
        defaultsName = "dish.test.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsName)
        store = ConnectionStore(defaults: defaults, keyStore: InMemoryKeyStore())
        willSleep = PassthroughSubject()
        didWake = PassthroughSubject()
        clamshell = FakeClamshell()
        lan = CountingLan()
        makeMoonlight()
        model = AppModel(
            store: store,
            lifecycle: LifecycleSignals(willSleep: willSleep.eraseToAnyPublisher(), didWake: didWake.eraseToAnyPublisher()),
            defaults: defaults,
            moonlight: moonlight,
            clamshell: clamshell,
            discovery: WifiConnectionManager.DiscoveryPaths { [lan] in lan.scan() }
        )
    }

    /// A host remembered as paired with Desktop picked, answering a launch, and edges that stream.
    private func makeMoonlight() {
        gateway = ScriptedMoonlightGateway()
        gateway.answerPlain("/serverinfo", .init(status: 200, body: MoonlightManagerTestCase.pairedInfo))
        gateway.answerSecure("/serverinfo", .init(status: 200, body: MoonlightManagerTestCase.pairedInfo))
        gateway.answerSecure("/applist", .init(status: 200, body: MoonlightManagerTestCase.appList))
        gateway.answerSecure("/launch", .init(status: 200, body: MoonlightManagerTestCase.launchOk))
        gateway.answerSecure("/cancel", .init(status: 200, body: MoonlightManagerTestCase.cancelled))
        edges = FakeMoonlightEdges()
        let hosts = MoonlightHostStore(defaults: defaults)
        var record = RememberedMoonlightHost(host: host, paired: true)
        record.uniqueId = "abc"
        record.lastAppId = "1"
        record.lastAppName = "Desktop"
        hosts.put(record)
        let lan = lan
        moonlight = MoonlightConnectionManager(
            store: hosts,
            gateway: gateway,
            identity: nil,
            edges: edges,
            discover: { lan?.browse() ?? [] },
            random: { count in Data(repeating: 0x42, count: count) },
            nonce: { "nonce" }
        )
    }

    override func tearDown() {
        bag.removeAll()
        model = nil
        defaults.removePersistentDomain(forName: defaultsName)
        super.tearDown()
    }

    private func waitUntil(timeout: TimeInterval = 8, _ predicate: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return predicate()
    }

    /// The pad bound to the Moonlight host, its session streaming and counted.
    private func streamToTheHost() async {
        model.input.slots = [pad]
        model.bind(slotId: pad.id, connectionId: host.id)
        await moonlight.awaitQuiet()
        let streaming = await waitUntil { self.model.streamingCount.state > 0 }
        XCTAssertTrue(streaming, "the bound pad streams")
    }

    private func sleepAndWake() async {
        willSleep.send(())
        await moonlight.awaitQuiet()
        didWake.send(())
        await moonlight.awaitQuiet()
    }

    // MARK: - Sleep

    func testSystemWillSleepZeroesAndSendsAllKnownDevices() {
        var reports: [(id: String, buttons: UInt16)] = []
        model.input.processor.reportSender = { id, report in
            reports.append((id, report.buttons))
        }
        var held = GamepadInputProcessor.DeviceState()
        held.buttons = 0x1000
        model.input.processor.publish(deviceId: "pad-a", state: held)
        model.input.processor.publish(deviceId: "pad-b", state: held)
        XCTAssertEqual(reports.count, 2)

        willSleep.send(())

        let releases = reports.dropFirst(2)
        XCTAssertEqual(Set(releases.map(\.id)), ["pad-a", "pad-b"], "a release-all per device")
        XCTAssertTrue(releases.allSatisfy { $0.buttons == 0 }, "the held buttons read released")
    }

    func testSleepClosesTheSatelliteSessionCleanlyAndWakeReopensIt() async throws {
        let satellite = try FakeSatellite()
        let ports = try satellite.start()
        defer { satellite.stop() }
        try satellite.requireHTTPSTransport()
        let server = DiscoveredServer(
            name: "Fake",
            ip: "127.0.0.1",
            udpPort: Int(ports.udp),
            pairPort: Int(ports.rest),
            httpPort: Int(ports.rest),
            machineId: satellite.machineId
        )
        let keyHex = String(repeating: "1f", count: 32)
        satellite.pairingKeyHex = keyHex
        store.setSharedKey(keyHex, for: server.id)
        model.connect(server)
        let live = await waitUntil { self.model.wifi.get(server.id)?.state == .live }
        XCTAssertTrue(live, "the keyed connect reaches live")

        willSleep.send(())

        let deleted = await waitUntil { satellite.lastTokenHex == nil }
        XCTAssertTrue(deleted, "sleep DELETEs the session on the satellite")
        XCTAssertEqual(model.wifi.get(server.id)?.state, .idle, "the row rests")
        XCTAssertNil(model.wifi.retry[server.id], "no retry is armed while the Mac sleeps")
        XCTAssertNotNil(store.sharedKey(for: server.id), "the pairing stays")

        didWake.send(())

        let reopened = await waitUntil { self.model.wifi.get(server.id)?.state == .live }
        XCTAssertTrue(reopened, "wake reopens the session")
        XCTAssertNotNil(satellite.lastTokenHex)
        model.wifi.disconnect(id: server.id)
    }

    func testSleepStopsTheMoonlightSessionAndWakeOpensItAgain() async throws {
        await streamToTheHost()
        let first = try XCTUnwrap(edges.liveSessions.last)

        willSleep.send(())
        await moonlight.awaitQuiet()

        XCTAssertTrue(first.stopped, "the control stream is closed")
        XCTAssertEqual(moonlight.get(host.id)?.phase, .idle)
        XCTAssertEqual(moonlight.get(host.id)?.pads.map(\.slotId), [pad.id], "the pad stays claimed for the wake")
        XCTAssertEqual(gateway.count(.secure, "/cancel"), 0, "the app is left running for the resume")

        didWake.send(())
        await moonlight.awaitQuiet()

        XCTAssertEqual(moonlight.get(host.id)?.phase, .streaming, "wake converges the binding again")
        XCTAssertEqual(edges.liveSessions.count, 2)
    }

    // MARK: - Wake

    func testSystemDidWakeReconnectsWithoutWaitingOutBackoff() async {
        let server = DiscoveredServer(name: "Napper", ip: "192.0.2.77", udpPort: 9876, machineId: "nap-sat")
        store.remember(server)
        model.wifi.retry[server.id] = WifiConnectionManager.RetryState(
            attempt: 5,
            nextRetryAtMs: WifiConnectionManager.nowMs() + 60000,
            suppressed: false
        )

        didWake.send(())

        let pooled = await waitUntil { self.model.wifi.connections[server.id] != nil }
        XCTAssertTrue(pooled, "wake reconnects the resting row now, not in 60 s")
        XCTAssertNil(model.wifi.retry[server.id], "the wake clears the stale time throttle")
    }

    func testSystemDidWakeKeepsReplacedSessionsSuppressed() async {
        let server = DiscoveredServer(name: "Replaced", ip: "192.0.2.78", udpPort: 9876, machineId: "replaced-sat")
        store.remember(server)
        model.wifi.retry[server.id] = WifiConnectionManager.RetryState(attempt: 1, nextRetryAtMs: 0, suppressed: true)

        didWake.send(())

        let resurrected = await waitUntil(timeout: 0.2) { self.model.wifi.connections[server.id] != nil }
        XCTAssertFalse(resurrected, "a session the satellite replaced stays parked through a wake")
        XCTAssertEqual(model.wifi.retry[server.id]?.suppressed, true)
    }

    func testWakeScansForSatellitesAndHostsAndAnEmptyLanSaysNothing() async {
        didWake.send(())

        let scanned = await waitUntil { self.lan.scans == 1 && self.lan.browses == 1 && !self.model.wifi.isScanning }
        XCTAssertTrue(scanned, "a laptop may wake on another network")
        XCTAssertNil(model.lastFailure, "the wake's scan hearing nothing is no failure to tell")
    }

    // MARK: - The lid

    func testALidThatClosedOnAStreamIsSaidOnceOnTheWake() async {
        var told = 0
        model.lidPausedStreaming.sink { told += 1 }.store(in: &bag)
        await streamToTheHost()
        clamshell.closed = true

        await sleepAndWake()
        XCTAssertEqual(told, 1)

        didWake.send(())
        XCTAssertEqual(told, 1, "a second wake after one sleep says nothing more")
    }

    func testTheLidIsNotMentionedWhenItStayedOpenOrNothingStreamed() async {
        var told = 0
        model.lidPausedStreaming.sink { told += 1 }.store(in: &bag)
        clamshell.closed = true
        await sleepAndWake()
        XCTAssertEqual(told, 0, "nothing streamed")

        await streamToTheHost()
        clamshell.closed = false
        await sleepAndWake()
        XCTAssertEqual(told, 0, "the lid stayed open: an ordinary sleep")
    }

    // MARK: - Manual add-by-address seeds the normal connect flow

    func testConnectManualSeedsPoolRowUnderLegacyIdentity() {
        XCTAssertTrue(model.connectManual("192.0.2.50"))
        XCTAssertNotNil(
            model.wifi.connections["wifi:192.0.2.50:9876"],
            "a manual add must register a pool row under the legacy wifi: identity"
        )

        XCTAssertFalse(model.connectManual("not-an-address"))
        XCTAssertEqual(model.wifi.connections.count, 1, "a rejected address must not seed anything")
    }

    // MARK: - Return-path wiring prune (gap G19)

    private static let server = DiscoveredServer(
        name: "Prune",
        ip: "192.0.2.60",
        udpPort: 9876,
        machineId: "prune-sat"
    )

    func testForgetThenReAddReinstallsReturnPathHandlers() {
        let id = Self.server.id
        let first = WifiConnection(id: id, server: Self.server, tickIntervalNs: .max)
        model.wifi.register(first)
        XCTAssertTrue(first.hasRumbleHandler, "a newly pooled connection gets the rumble handler")
        XCTAssertTrue(first.hasLightbarHandler, "…and the light-bar handler")

        model.wifi.forget(id: id)

        // The same satellite id re-appears (re-discovered after a forget):
        // the fresh WifiConnection must be wired again. Before the prune fix
        // the grow-only set skipped this install and the new session had no
        // rumble/light-bar return path.
        let second = WifiConnection(id: id, server: Self.server, tickIntervalNs: .max)
        model.wifi.register(second)
        XCTAssertTrue(second.hasRumbleHandler, "re-added id must be re-wired (grow-only set bug)")
        XCTAssertTrue(second.hasLightbarHandler)
    }

    func testNewlyRegisteredConnectionIsWiredImmediately() {
        // The install walk must use the EMITTED pool: `@Published` delivers
        // in willSet, so re-reading the manager property during delivery
        // misses the entry that just registered.
        let conn = WifiConnection(id: Self.server.id, server: Self.server, tickIntervalNs: .max)
        model.wifi.register(conn)
        XCTAssertTrue(
            conn.hasRumbleHandler,
            "the connection that triggered the pool change must be wired in the same pass"
        )
    }

    // MARK: - afterMutationSettles (gap G19 helper)

    private final class Box: ObservableObject {
        @Published var value = 0
    }

    func testAfterMutationSettlesDeliversPostMutationState() async {
        let box = Box()
        var observedDirect = [Int]()
        var observedSettled = [Int]()

        // Control: a raw sink on objectWillChange reads the PRIOR value —
        // that is the trap the helper exists to close.
        box.objectWillChange
            .sink { _ in observedDirect.append(box.value) }
            .store(in: &bag)
        box.objectWillChange
            .afterMutationSettles()
            .sink { _ in observedSettled.append(box.value) }
            .store(in: &bag)

        box.value = 7
        XCTAssertEqual(observedDirect, [0], "willSet timing: the raw sink sees the stale value")
        let settled = await waitUntil { observedSettled == [7] }
        XCTAssertTrue(settled, "the helper must deliver post-mutation state")
    }
}

/// A lid the test opens and closes.
private final class FakeClamshell: ClamshellStateReading {
    var closed = false

    func lidIsClosed() -> Bool {
        closed
    }
}

/// An empty LAN that counts how often each kind of host was looked for.
private final class CountingLan: @unchecked Sendable {
    private let lock = NSLock()
    private var scanCount = 0
    private var browseCount = 0

    var scans: Int {
        lock.withLock { scanCount }
    }

    var browses: Int {
        lock.withLock { browseCount }
    }

    func scan() -> WifiConnectionManager.ScanResult {
        lock.withLock { scanCount += 1 }
        return WifiConnectionManager.ScanResult(broadcast: [], mdns: [])
    }

    func browse() -> [MoonlightHost] {
        lock.withLock { browseCount += 1 }
        return []
    }
}
