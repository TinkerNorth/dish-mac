// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Combine
import DishCore
import XCTest
@testable import DishEngine

/// The pairing intents through the composition root: a satellite that asks
/// to pair opens its card with a fresh client PIN, the typed PIN and the
/// operator's approval both open the session and close the card, a new code
/// refiles, a cancel or leaving the sheet stops the poll, and the open card's
/// failures stay on the card while every other one still reaches the toast.
@MainActor
final class AppModelPairingTests: XCTestCase {

    private var satellite: FakeSatellite!
    private var ports: FakeSatellite.Ports!
    private var defaults: UserDefaults!
    private var defaultsName: String!
    private var store: ConnectionStore!
    private var model: AppModel!
    private var toasted: [ConnectionFailure] = []
    private var bag = Set<AnyCancellable>()

    override func setUpWithError() throws {
        try super.setUpWithError()
        satellite = try FakeSatellite()
        ports = try satellite.start()
        try satellite.requireHTTPSTransport()
        defaultsName = "dish.test.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsName)
        store = ConnectionStore(defaults: defaults, keyStore: InMemoryKeyStore())
        model = AppModel(
            store: store,
            defaults: defaults,
            discovery: WifiConnectionManager.DiscoveryPaths { WifiConnectionManager.ScanResult(broadcast: [], mdns: []) },
            approvalPolling: WifiConnectionManager.ApprovalPolling(intervalMs: 50, timeoutMs: 20000)
        )
        toasted = []
        model.failures
            .sink { [weak self] failure in self?.toasted.append(failure) }
            .store(in: &bag)
    }

    override func tearDown() {
        bag.removeAll()
        for id in model.wifi.connections.keys {
            model.wifi.disconnect(id: id)
        }
        model = nil
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

    /// The card is open on the satellite and its request has been polled.
    private func openTheCard() async {
        model.beginPairing(server)
        let filed = await waitUntil { self.satellite.pairStatusPolls >= 1 }
        XCTAssertTrue(filed, "the request is filed and polled")
    }

    // MARK: - Opening the card

    func testASatelliteThatAsksToPairOpensItsCardWithAFreshFourDigitCode() async throws {
        model.connect(server)
        let opened = await waitUntil { self.model.openPairing != nil }
        XCTAssertTrue(opened, "the probe's pairing-required opens the card")
        let open = try XCTUnwrap(model.openPairing)
        XCTAssertEqual(open.server.id, server.id)
        XCTAssertEqual(open.attempt.phase, .awaiting)
        XCTAssertEqual(open.attempt.clientPin.count, 4)
        XCTAssertTrue(open.attempt.clientPin.allSatisfy(\.isNumber))
        let filed = await waitUntil { self.satellite.lastClientPin == open.attempt.clientPin }
        XCTAssertTrue(filed, "the request the satellite holds carries the code the card shows")
    }

    func testARowsPairButtonOpensTheCardForAScannedSatellite() {
        model.wifi.publishScan([server])
        model.beginPairing(serverId: server.id)
        XCTAssertEqual(model.pairingTarget?.id, server.id)
        XCTAssertEqual(model.openPairing?.attempt.phase, .awaiting)
    }

    func testAPairButtonForAnUnknownSatelliteDoesNothing() {
        model.beginPairing(serverId: "mid:nobody")
        XCTAssertNil(model.pairingTarget)
        XCTAssertEqual(model.pairingAttempts, [:])
    }

    func testOpeningAnotherSatellitesCardCancelsTheFirst() async {
        await openTheCard()
        let other = DiscoveredServer(name: "Other", ip: "127.0.0.1", udpPort: 1, pairPort: 1)
        model.beginPairing(other)
        XCTAssertEqual(model.pairingTarget?.id, other.id)
        XCTAssertNil(model.pairingAttempts[server.id], "one card at a time; the first stopped")
        XCTAssertNil(model.wifi.approvalPolls[server.id])
    }

    // MARK: - Closing the card

    func testTheTypedPinPairsAndTheCardCloses() async {
        await openTheCard()
        model.submitPin(server.id, pin: satellite.operatorPin)
        let live = await waitUntil { self.model.wifi.get(self.server.id)?.state == .live }
        XCTAssertTrue(live)
        XCTAssertNil(model.pairingTarget, "the session took over from the card")
        XCTAssertNil(model.openPairing)
    }

    func testTheOperatorsApprovalClosesTheCardOnceTheSessionOpens() async {
        await openTheCard()
        satellite.approveClientPin()
        let live = await waitUntil { self.model.wifi.get(self.server.id)?.state == .live }
        XCTAssertTrue(live)
        let closed = await waitUntil { self.model.pairingTarget == nil }
        XCTAssertTrue(closed)
    }

    func testCancelClosesTheCardAndStopsThePoll() async {
        await openTheCard()
        model.cancelPairing(server.id)
        XCTAssertNil(model.pairingTarget)
        XCTAssertNil(model.pairingAttempts[server.id])
        XCTAssertNil(model.wifi.approvalPolls[server.id], "no poll outlives the card")
    }

    func testLeavingTheConnectionsSheetCancelsTheOpenCard() async {
        await openTheCard()
        model.leftConnections()
        XCTAssertNil(model.pairingTarget)
        XCTAssertNil(model.wifi.approvalPolls[server.id])
    }

    func testLeavingTheSheetWithNoCardOpenTouchesNothing() {
        model.leftConnections()
        XCTAssertNil(model.pairingTarget)
    }

    // MARK: - A new code

    func testNewCodeAfterADeclineFilesAFreshRequest() async {
        await openTheCard()
        satellite.denyClientPin()
        let declined = await waitUntil { self.model.openPairing?.attempt.phase == .declined }
        XCTAssertTrue(declined, "the card stays open on the decline")
        XCTAssertNil(satellite.lastClientPin, "the decline erased the request")
        model.newCode(server.id)
        XCTAssertEqual(model.openPairing?.attempt.phase, .awaiting)
        let refiled = await waitUntil { self.satellite.lastClientPin != nil }
        XCTAssertTrue(refiled)
        XCTAssertEqual(satellite.lastClientPin, model.openPairing?.attempt.clientPin)
    }

    // MARK: - Where a failure is told

    func testTheOpenCardsFailuresStayOnTheCard() async {
        await openTheCard()
        model.submitPin(server.id, pin: "0000")
        let rejected = await waitUntil { self.model.openPairing?.attempt.rejection == .wrongPin }
        XCTAssertTrue(rejected)
        satellite.denyClientPin()
        let declined = await waitUntil { self.model.openPairing?.attempt.phase == .declined }
        XCTAssertTrue(declined)
        XCTAssertEqual(toasted, [], "the card says both itself")
        XCTAssertNil(model.lastFailure)
    }

    func testAPairingFailureForASatelliteWithNoOpenCardIsToasted() async {
        await openTheCard()
        model.reportPairingFailure(serverId: "mid:other", .approvalDeclined)
        XCTAssertEqual(toasted, [.approvalDeclined])
    }

    func testAnUnrelatedFailureStillToastsWhileTheCardIsOpen() async {
        await openTheCard()
        model.wifi.events.send(.failure(.noServersFound))
        XCTAssertEqual(toasted, [.noServersFound])
        XCTAssertEqual(model.lastFailure, .noServersFound)
    }

    // MARK: - Redraws

    func testEveryAttemptChangeRedrawsTheModel() {
        var redraws = 0
        model.objectWillChange
            .sink { redraws += 1 }
            .store(in: &bag)
        model.wifi.pairingAttempts.awaitApproval("mid:x", clientPin: "1234")
        model.wifi.pairingAttempts.finish("mid:x", phase: .declined)
        XCTAssertGreaterThanOrEqual(redraws, 2)
    }
}
