// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Combine
import XCTest
@testable import DishEngine

/// A scan's outcome as the manager tells it: what it publishes and which
/// failure it says. The LAN is scripted, one answer per scan.
@MainActor
final class DiscoveryScanTests: XCTestCase {

    private var defaults: UserDefaults!
    private var defaultsName = ""
    private var events: [ConnectionEvent] = []
    private var bag = Set<AnyCancellable>()

    private let basement = DiscoveredServer(name: "Basement", ip: "10.0.0.7", machineId: "m-basement")

    override func setUp() {
        super.setUp()
        defaultsName = "dish.test.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsName)
        events = []
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: defaultsName)
        bag = []
        super.tearDown()
    }

    private func makeManager(lan: ScriptedLAN) -> WifiConnectionManager {
        let store = ConnectionStore(defaults: defaults, keyStore: InMemoryKeyStore())
        let paths = WifiConnectionManager.DiscoveryPaths { lan.next() }
        let manager = WifiConnectionManager(store: store, discovery: paths)
        manager.events
            .sink { [weak self] event in self?.events.append(event) }
            .store(in: &bag)
        return manager
    }

    private func scanToTheEnd(_ manager: WifiConnectionManager, trigger: WifiConnectionManager.ScanTrigger = .user) async {
        manager.startDiscovery(trigger: trigger)
        XCTAssertTrue(manager.isScanning)
        let settled = await waitUntil { !manager.isScanning }
        XCTAssertTrue(settled, "the scan never finished")
    }

    private func waitUntil(timeout: TimeInterval = 5, _ predicate: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return predicate()
    }

    // MARK: - What a scan says

    func testAScanThatHeardAServerPublishesItAndSaysNothing() async {
        let lan = ScriptedLAN([.init(broadcast: [basement], mdns: [])])
        let manager = makeManager(lan: lan)
        await scanToTheEnd(manager)
        XCTAssertEqual(manager.discoveredServers.map(\.id), [basement.id])
        XCTAssertEqual(events, [])
        XCTAssertEqual(lan.scans, 1)
    }

    func testAnEmptyScanSaysNoServersFound() async {
        let lan = ScriptedLAN([.init(broadcast: [], mdns: [])])
        let manager = makeManager(lan: lan)
        await scanToTheEnd(manager)
        XCTAssertEqual(manager.discoveredServers, [])
        XCTAssertEqual(events, [.failure(.noServersFound)])
        XCTAssertEqual(lan.scans, 1)
    }

    // MARK: - A refused local network

    func testAScanMacOSRefusedSaysSo() async {
        let lan = ScriptedLAN([.init(broadcast: [], mdns: [], localNetworkDenied: true)])
        let manager = makeManager(lan: lan)
        await scanToTheEnd(manager)
        XCTAssertEqual(manager.discoveredServers, [])
        XCTAssertEqual(events, [.failure(.localNetworkDenied)])
        XCTAssertEqual(lan.scans, 1)
    }

    func testAScanMacOSRefusedLeavesTheRefusalForTheEmptyState() async {
        let lan = ScriptedLAN([.init(broadcast: [], mdns: [], localNetworkDenied: true), .init(broadcast: [basement], mdns: [])])
        let manager = makeManager(lan: lan)
        await scanToTheEnd(manager)
        XCTAssertTrue(manager.localNetworkDenied)
        await scanToTheEnd(manager)
        XCTAssertFalse(manager.localNetworkDenied, "the next open scan clears it")
    }

    func testAScanAPageRunsAsItOpensSaysNothingOfAnEmptyOrRefusedNetwork() async {
        let lan = ScriptedLAN([.init(broadcast: [], mdns: [], localNetworkDenied: true)])
        let manager = makeManager(lan: lan)
        await scanToTheEnd(manager, trigger: .pageOpened)
        XCTAssertEqual(events, [])
        XCTAssertTrue(manager.localNetworkDenied, "the page's empty state says it instead")
    }

    func testARefusalIsSaidEvenWhenAServerWasHeard() async {
        // A beacon can slip through before the block lands; the row shows,
        // and the refusal is still what the user needs to hear.
        let lan = ScriptedLAN([.init(broadcast: [basement], mdns: [], localNetworkDenied: true)])
        let manager = makeManager(lan: lan)
        await scanToTheEnd(manager)
        XCTAssertEqual(manager.discoveredServers.map(\.id), [basement.id])
        XCTAssertEqual(events, [.failure(.localNetworkDenied)])
    }

    func testASecondScanWhileOneRunsIsDropped() async {
        let lan = ScriptedLAN([.init(broadcast: [], mdns: [])])
        let manager = makeManager(lan: lan)
        manager.startDiscovery()
        manager.startDiscovery()
        let settled = await waitUntil { !manager.isScanning }
        XCTAssertTrue(settled)
        XCTAssertEqual(lan.scans, 1, "the second request started nothing")
        XCTAssertEqual(events, [.failure(.noServersFound)])
    }
}

/// A LAN that answers each scan from a script, then repeats its last answer.
private final class ScriptedLAN: @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [WifiConnectionManager.ScanResult]
    private var count = 0

    init(_ answers: [WifiConnectionManager.ScanResult]) {
        self.answers = answers
    }

    var scans: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func next() -> WifiConnectionManager.ScanResult {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return answers.count > 1 ? answers.removeFirst() : answers[0]
    }
}
