// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Combine
import XCTest
@testable import DishCore
@testable import DishEngine

/// The Connections pages' intents through the composition root: the scan a
/// page runs as it opens is quiet while the Scan button's speaks, the facts
/// the pages draw follow the scans, a Forget waits for its answer, a typed
/// address is read in the model, and a row's buttons dispatch there.
@MainActor
final class AppModelConnectionsTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suite: String!
    private var store: ConnectionStore!
    private var gateway: ScriptedMoonlightGateway!
    private var moonlight: MoonlightConnectionManager!
    private var model: AppModel!
    private var toasted: [ConnectionFailure] = []
    private var hostEvents: [MoonlightConnectionEvent] = []
    private var bag = Set<AnyCancellable>()

    private let den = DiscoveredServer(name: "Den", ip: "192.0.2.10", machineId: "den")
    private let host = MoonlightHost(name: "PC", address: "10.0.0.5", uniqueId: "abc")

    override func setUp() {
        super.setUp()
        suite = "dish.test.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        store = ConnectionStore(defaults: defaults, keyStore: InMemoryKeyStore())
        gateway = ScriptedMoonlightGateway()
        moonlight = MoonlightConnectionManager(
            store: MoonlightHostStore(defaults: defaults),
            gateway: gateway,
            identity: nil,
            edges: FakeMoonlightEdges(),
            discover: { [] }
        )
        model = AppModel(
            store: store,
            defaults: defaults,
            moonlight: moonlight,
            discovery: WifiConnectionManager.DiscoveryPaths(scan: Self.aQuietLAN)
        )
        toasted = []
        hostEvents = []
        model.failures
            .sink { [weak self] failure in self?.toasted.append(failure) }
            .store(in: &bag)
        moonlight.events
            .sink { [weak self] event in self?.hostEvents.append(event) }
            .store(in: &bag)
    }

    /// A sweep that hears nothing, slow enough for the page to see it run.
    private static let aQuietLAN: @Sendable () async -> WifiConnectionManager.ScanResult = {
        try? await Task.sleep(nanoseconds: 200_000_000)
        return WifiConnectionManager.ScanResult(broadcast: [], mdns: [])
    }

    override func tearDown() {
        bag.removeAll()
        model = nil
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func waitUntil(timeout: TimeInterval = 5, _ predicate: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return predicate()
    }

    private func rememberDen() {
        store.remember(den)
        model.wifi.register(WifiConnection(id: den.id, server: den, tickIntervalNs: .max))
    }

    // MARK: - Scanning

    func testThePageOpensWithAScanThatSaysNothingOfAnEmptyNetwork() async {
        model.pageAppeared(.connections)
        XCTAssertTrue(model.wifi.isScanning, "the page scans as it opens")
        let settled = await waitUntil { !model.wifi.isScanning }
        XCTAssertTrue(settled)
        let drawn = await waitUntil { !model.shellFacts.connections.scanning }
        XCTAssertTrue(drawn, "the page's facts follow the scan")
        XCTAssertEqual(toasted, [], "the empty state speaks, not a toast")
    }

    func testTheScanButtonSaysNothingWasFound() async {
        model.startScan()
        let told = await waitUntil { !self.toasted.isEmpty }
        XCTAssertTrue(told)
        XCTAssertEqual(toasted, [.noServersFound])
    }

    func testTheFactsCarryWhatTheScanIsDoing() async {
        model.startScan()
        let scanning = await waitUntil { model.shellFacts.connections.scanning }
        XCTAssertTrue(scanning)
        let done = await waitUntil { !model.shellFacts.connections.scanning }
        XCTAssertTrue(done)
        XCTAssertEqual(model.shellFacts.connections.discovered, [])
        XCTAssertFalse(model.shellFacts.connections.localNetworkDenied)
    }

    func testTheMoonlightHostsPageScansOnlyItsHosts() {
        model.pageAppeared(.moonlightHosts)
        XCTAssertFalse(model.wifi.isScanning, "the satellites are not swept from this page")
    }

    // MARK: - Forget asks first

    func testAForgetWaitsForItsAnswerAndCancelKeepsTheSatellite() {
        rememberDen()
        model.requestForget(den.id)
        XCTAssertEqual(model.shellFacts.connections.pendingForget, den.id)
        XCTAssertEqual(model.wifi.remembered().map(\.id), [den.id], "nothing is forgotten before the answer")
        model.cancelForget()
        XCTAssertNil(model.shellFacts.connections.pendingForget)
        XCTAssertEqual(model.wifi.remembered().map(\.id), [den.id])
    }

    func testConfirmingForgetsTheSatelliteAndItsBinding() {
        rememberDen()
        model.input.slots = [GameControllerInput.Slot(id: "pad", name: "Pad", capabilities: .none, battery: nil, family: .other)]
        model.bind(slotId: "pad", connectionId: den.id)
        model.requestForget(den.id)
        model.confirmForget()
        XCTAssertNil(model.shellFacts.connections.pendingForget)
        XCTAssertEqual(model.wifi.remembered(), [])
        XCTAssertEqual(model.hub.bindings, [:], "the bindings go first")
    }

    func testConfirmingWithNothingWaitingForgetsNothing() {
        rememberDen()
        model.confirmForget()
        XCTAssertEqual(model.wifi.remembered().map(\.id), [den.id])
    }

    // MARK: - A typed address

    func testASatelliteAddressThatDoesNotReadIsTheFieldsErrorUntilOneDoes() {
        XCTAssertFalse(model.addByAddress(.satellite, "not-an-address"))
        XCTAssertEqual(model.shellFacts.connections.rejectedAddress, .satellite)
        XCTAssertTrue(model.addByAddress(.satellite, "192.0.2.50"))
        XCTAssertNil(model.shellFacts.connections.rejectedAddress)
        XCTAssertNotNil(model.wifi.connections["wifi:192.0.2.50:9876"])
    }

    func testABlankMoonlightAddressIsRefusedAndATypedOneIsProbedTrimmed() async {
        XCTAssertFalse(model.addByAddress(.moonlight, "   "))
        XCTAssertEqual(model.shellFacts.connections.rejectedAddress, .moonlight)
        model.clearAddressError()
        XCTAssertNil(model.shellFacts.connections.rejectedAddress)
        XCTAssertTrue(model.addByAddress(.moonlight, "  10.0.0.9 \n"))
        let probed = await waitUntil { !self.hostEvents.isEmpty }
        XCTAssertTrue(probed)
        XCTAssertEqual(hostEvents, [.noHostAnswered(address: "10.0.0.9")], "the scripted host stays silent")
    }

    func testMoonlightAddressesAreTrimmedAndABlankOneIsNone() {
        XCTAssertEqual(moonlightAddress(from: " pc.local "), "pc.local")
        XCTAssertNil(moonlightAddress(from: " \n "))
    }

    // MARK: - A row's buttons

    func testASatelliteCardsButtonsReachTheManager() {
        rememberDen()
        model.perform(.pair, on: den.id)
        XCTAssertEqual(model.pairingTarget?.id, den.id, "Pair… opens the card")
        model.cancelPairing(den.id)
        model.perform(.connect, on: den.id)
        XCTAssertNotEqual(model.wifi.connections[den.id]?.state, .idle, "Connect opens a session at the remembered address")
        model.perform(.disconnect, on: den.id)
        XCTAssertEqual(model.wifi.connections[den.id]?.state, .idle)
    }

    func testAPickedAppIsNamedByWhatTheProbeListed() {
        moonlight.store.put(RememberedMoonlightHost(host: host, paired: true))
        moonlight.publishRemembered()
        moonlight.hostApps[host.id] = [MoonlightApp(id: "7", title: "Steam", hdrSupported: false)]
        model.pickMoonlightApp(host.id, appId: "7")
        XCTAssertEqual(moonlight.rememberedAppId(hostId: host.id), "7")
        XCTAssertEqual(moonlight.rememberedAppName(hostId: host.id), "Steam")
        model.pickMoonlightApp(host.id, appId: "")
        XCTAssertEqual(moonlight.rememberedAppId(hostId: host.id), "", "Auto")
        XCTAssertEqual(moonlight.rememberedAppName(hostId: host.id), "")
    }

    func testLeavingTheMoonlightHostsPageEndsThePairingItsPinWaitsOn() {
        moonlight.events.send(.pairingPinReady(host: host, pin: "0451"))
        XCTAssertNotNil(model.moonlightPin)
        model.pageDisappeared(.moonlightHosts)
        XCTAssertNil(model.moonlightPin)
        XCTAssertEqual(moonlight.pairingGenerations[host.id], 1)
    }
}
