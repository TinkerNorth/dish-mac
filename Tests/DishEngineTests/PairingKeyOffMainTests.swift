// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Combine
import DishCore
import XCTest
@testable import DishEngine

/// A Keychain read of a pairing key another build saved waits until the
/// user answers macOS's access prompt, and every ad-hoc build is another
/// build. The manager reads the key off the main actor, so the window keeps
/// drawing while macOS asks, and every flow that reads it does so off the
/// main thread.
@MainActor
final class PairingKeyOffMainTests: XCTestCase {

    private var satellite: FakeSatellite!
    private var ports: FakeSatellite.Ports!
    private var defaults: UserDefaults!
    private var defaultsName: String!
    private var keys: AskingKeyStore!
    private var store: ConnectionStore!
    private var manager: WifiConnectionManager!

    private let keyHex = String(repeating: "1f", count: 32)

    override func setUpWithError() throws {
        try super.setUpWithError()
        satellite = try FakeSatellite()
        ports = try satellite.start()
        try satellite.requireHTTPSTransport()
        defaultsName = "dish.test.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsName)
        keys = AskingKeyStore()
        store = ConnectionStore(defaults: defaults, keyStore: keys)
        manager = WifiConnectionManager(store: store)
        satellite.pairingKeyHex = keyHex
        store.setSharedKey(keyHex, for: server.id)
    }

    override func tearDown() {
        keys.answer()
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

    private func waitUntil(timeout: TimeInterval = 5, _ predicate: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return predicate()
    }

    // MARK: - While macOS asks

    func testTheMainActorRunsWhileAnAutoReconnectWaitsOnTheKeychain() async {
        store.remember(server)
        manager.autoReconnectAll()
        let ranWhileAsking = await waitUntil(timeout: 2) { self.keys.waiting == 1 }
        XCTAssertTrue(ranWhileAsking, "the main actor ran while the read waited on the user")
        keys.answer()
        let live = await waitUntil { self.manager.get(self.server.id)?.state == .live }
        XCTAssertTrue(live, "once answered, the session opens")
        XCTAssertEqual(keys.mainThreadReads, 0)
    }

    // MARK: - Every read of a session

    func testNoPairingKeyReadOfASessionRunsOnTheMainThread() async throws {
        keys.answer()
        let live = await connectAndWaitForLive()
        XCTAssertTrue(live)
        let conn = try XCTUnwrap(manager.get(server.id))
        conn.convergeIndices([0])
        await manager.syncSlots(conn)
        await manager.runReconcile(conn)
        await manager.rekeySession(conn)
        let readsBeforeClose = keys.reads
        manager.disconnect(id: server.id)
        let closeRead = await waitUntil { self.keys.reads > readsBeforeClose }
        XCTAssertTrue(closeRead, "the session's DELETE carries a proof")
        manager.forget(id: server.id)
        let unpaired = await waitUntil { self.satellite.unpairCalls.count == 1 }
        XCTAssertTrue(unpaired, "forget still self-unpairs with the key")
        XCTAssertGreaterThanOrEqual(keys.reads, 7, "connect, open, slot, reconcile, re-key, close and unpair each read the key")
        XCTAssertEqual(keys.mainThreadReads, 0, "no read ran on the main thread")
    }

    private func connectAndWaitForLive() async -> Bool {
        manager.connect(to: server)
        return await waitUntil { self.manager.get(self.server.id)?.state == .live }
    }
}

/// A key store whose reads wait for the user the way a Keychain read waits
/// on macOS's access prompt, and which counts the reads made on the main
/// thread. A read gives up after `patienceSeconds`, so one made on the main
/// thread still lets the test end.
private final class AskingKeyStore: KeyStore, @unchecked Sendable {
    private static let patienceSeconds: TimeInterval = 3

    private let keys = InMemoryKeyStore()
    private let answered = LockedBox(false)
    private let waitingBox = LockedBox(0)
    private let readsBox = LockedBox(0)
    private let mainThreadReadsBox = LockedBox(0)

    /// Reads waiting on the user right now.
    var waiting: Int {
        waitingBox.get()
    }

    var reads: Int {
        readsBox.get()
    }

    var mainThreadReads: Int {
        mainThreadReadsBox.get()
    }

    /// The user answers: this read and every later one go through at once.
    func answer() {
        answered.set(true)
    }

    func pairingKeyHex(for id: String) -> String? {
        readsBox.mutate { $0 += 1 }
        if Thread.isMainThread { mainThreadReadsBox.mutate { $0 += 1 } }
        waitForTheAnswer()
        return keys.pairingKeyHex(for: id)
    }

    func setPairingKeyHex(_ keyHex: String, for id: String) -> Bool {
        keys.setPairingKeyHex(keyHex, for: id)
    }

    func removePairingKey(for id: String) {
        keys.removePairingKey(for: id)
    }

    private func waitForTheAnswer() {
        waitingBox.mutate { $0 += 1 }
        defer { waitingBox.mutate { $0 -= 1 } }
        let deadline = Date().addingTimeInterval(Self.patienceSeconds)
        while !answered.get(), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
    }
}
