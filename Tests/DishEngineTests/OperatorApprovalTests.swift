// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// Both pairing paths at once against FakeSatellite, as the pairing card runs
// them: the operator request publishes its client PIN and phase, the typed
// PIN publishes its rejections, a cancel stops the poll, and whichever path
// lands first opens the session while the other stops.

import Combine
import DishCore
import XCTest
@testable import DishEngine

@MainActor
final class OperatorApprovalTests: XCTestCase {

    private var satellite: FakeSatellite!
    private var ports: FakeSatellite.Ports!
    private var defaults: UserDefaults!
    private var defaultsName: String!
    private var store: ConnectionStore!
    private var manager: WifiConnectionManager!
    private var events: [ConnectionEvent] = []
    private var bag = Set<AnyCancellable>()

    private static let fastPolling = WifiConnectionManager.ApprovalPolling(intervalMs: 50, timeoutMs: 20000)

    override func setUpWithError() throws {
        try super.setUpWithError()
        satellite = try FakeSatellite()
        ports = try satellite.start()
        try satellite.requireHTTPSTransport()
        defaultsName = "dish.test.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsName)
        store = ConnectionStore(defaults: defaults, keyStore: InMemoryKeyStore())
        makeManager(polling: Self.fastPolling)
    }

    private func makeManager(polling: WifiConnectionManager.ApprovalPolling) {
        manager = WifiConnectionManager(store: store, approvalPolling: polling)
        events = []
        bag.removeAll()
        manager.events
            .sink { [weak self] event in self?.events.append(event) }
            .store(in: &bag)
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

    private var id: String {
        server.id
    }

    private var attempt: PairingAttempt? {
        manager.pairingAttempts.state[id]
    }

    private var pairingFailures: [ConnectionFailure] {
        events.compactMap {
            if case let .pairingFailed(serverId, failure) = $0, serverId == id { return failure }
            return nil
        }
    }

    private func waitUntil(timeout: TimeInterval = 5, _ predicate: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return predicate()
    }

    /// The request is filed and at least one poll has read "pending".
    private func requestFiled(_ clientPin: String) async -> Bool {
        let filed = await waitUntil { self.satellite.lastClientPin == clientPin }
        let polled = await waitUntil { self.satellite.pairStatusPolls >= 1 }
        return filed && polled
    }

    /// The poll count holds still across a few intervals.
    private func pollsHaveStopped() async -> Bool {
        try? await Task.sleep(nanoseconds: 200_000_000)
        let settled = satellite.pairStatusPolls
        try? await Task.sleep(nanoseconds: 250_000_000)
        return satellite.pairStatusPolls == settled
    }

    // MARK: - The phase, published

    func testARequestPublishesItsClientPinAndAwaitsTheOperator() async {
        manager.pairWithClientPin(server, clientPin: "4081")
        XCTAssertEqual(attempt, PairingAttempt(clientPin: "4081", phase: .awaiting), "published before the POST lands")
        let filed = await requestFiled("4081")
        XCTAssertTrue(filed)
        XCTAssertEqual(attempt?.phase, .awaiting)
        XCTAssertEqual(pairingFailures, [])
    }

    func testADeclineIsPublishedAndKeyedToTheSatellite() async {
        manager.pairWithClientPin(server, clientPin: "9911")
        let filed = await requestFiled("9911")
        XCTAssertTrue(filed)
        satellite.denyClientPin()
        let declined = await waitUntil { self.attempt?.phase == .declined }
        XCTAssertTrue(declined, "a none after the pending is the operator's decline")
        XCTAssertEqual(attempt?.clientPin, "9911", "the card still names the code it showed")
        XCTAssertEqual(pairingFailures, [.approvalDeclined])
        XCTAssertNil(store.sharedKey(for: id))
        XCTAssertEqual(manager.get(id)?.state, .idle)
    }

    func testADeclineBeforeTheFirstPollIsStillADecline() async {
        makeManager(polling: WifiConnectionManager.ApprovalPolling(intervalMs: 400, timeoutMs: 20000))
        manager.pairWithClientPin(server, clientPin: "7070")
        let filed = await waitUntil { self.satellite.lastClientPin == "7070" }
        XCTAssertTrue(filed)
        satellite.denyClientPin()
        let declined = await waitUntil { self.attempt?.phase == .declined }
        XCTAssertTrue(declined, "the submit's own pending answer counts as the pending seen")
        XCTAssertEqual(satellite.pairStatusPolls, 1, "one poll was enough")
    }

    func testAnApprovalOpensTheSessionAndTheAttemptEnds() async {
        manager.pairWithClientPin(server, clientPin: "1234")
        let filed = await requestFiled("1234")
        XCTAssertTrue(filed)
        satellite.approveClientPin()
        let live = await waitUntil { self.manager.get(self.id)?.state == .live }
        XCTAssertTrue(live)
        XCTAssertNil(attempt, "the session took over; the card has nothing left to say")
        XCTAssertEqual(store.sharedKey(for: id), satellite.pairingKeyHex)
        XCTAssertNil(manager.approvalPolls[id])
    }

    func testNoAnswerTimesOutAtTheInclusiveDeadline() async {
        makeManager(polling: WifiConnectionManager.ApprovalPolling(intervalMs: 50, timeoutMs: 150))
        manager.pairWithClientPin(server, clientPin: "5555")
        let timedOut = await waitUntil { self.attempt?.phase == .timedOut }
        XCTAssertTrue(timedOut)
        XCTAssertEqual(satellite.pairStatusPolls, 3, "polls at 50, 100 and 150 ms; the third spends the budget")
        XCTAssertEqual(pairingFailures, [.approvalTimedOut])
        let stopped = await pollsHaveStopped()
        XCTAssertTrue(stopped)
    }

    func testATransportBlipKeepsThePollAlive() async {
        satellite.pairStatusBlips = 3
        manager.pairWithClientPin(server, clientPin: "2468")
        let blipped = await waitUntil { self.satellite.pairStatusPolls >= 4 }
        XCTAssertTrue(blipped, "three unreadable answers, and the poll asked again")
        XCTAssertEqual(attempt?.phase, .awaiting)
        satellite.approveClientPin()
        let live = await waitUntil { self.manager.get(self.id)?.state == .live }
        XCTAssertTrue(live)
        XCTAssertEqual(pairingFailures, [])
    }

    func testAnUnreachableSatelliteEndsTheRequestAsExpired() async throws {
        let closedPort = try XCTUnwrap(ports)
        satellite.stop()
        let gone = DiscoveredServer(name: "Gone", ip: "127.0.0.1", udpPort: Int(closedPort.udp), pairPort: Int(closedPort.rest))
        manager.pairWithClientPin(gone, clientPin: "1357")
        let ended = await waitUntil { self.manager.pairingAttempts.state[gone.id]?.phase == .timedOut }
        XCTAssertTrue(ended, "a request that never landed can only be retried with a new code")
    }

    func testAVersionTheSatelliteCannotSpeakEndsTheRequest() async {
        satellite.protocolRange = 4 ... 5
        manager.pairWithClientPin(server, clientPin: "8642")
        let ended = await waitUntil { self.attempt?.phase == .versionMismatch }
        XCTAssertTrue(ended)
        XCTAssertEqual(pairingFailures, [.dishUpdateRequired])
    }

    func testAChangedIdentityAtTheSubmitEndsTheRequest() async {
        store.setCertPin(host: "127.0.0.1", fingerprintHex: String(repeating: "00", count: 32))
        manager.pairWithClientPin(server, clientPin: "1111")
        let ended = await waitUntil { self.attempt?.phase == .identityChanged }
        XCTAssertTrue(ended)
        XCTAssertEqual(pairingFailures, [.identityChanged])
    }

    func testAChangedIdentityDuringThePollEndsTheRequest() async throws {
        let imposter = try FakeSatellite(machineId: satellite.machineId)
        let imposterPorts = try imposter.start()
        defer { imposter.stop() }
        let split = DiscoveredServer(
            name: "Fake",
            ip: "127.0.0.1",
            udpPort: Int(ports.udp),
            pairPort: Int(ports.rest),
            httpPort: Int(imposterPorts.rest),
            machineId: satellite.machineId
        )
        manager.pairWithClientPin(split, clientPin: "3141")
        let ended = await waitUntil { self.attempt?.phase == .identityChanged }
        XCTAssertTrue(ended, "the poll met a certificate the submit did not pin")
        XCTAssertEqual(pairingFailures, [.identityChanged])
        XCTAssertEqual(imposter.pairStatusPolls, 0, "the handshake aborts before a request leaves")
    }

    // MARK: - Cancel

    func testCancelStopsThePollAndRestsTheRow() async {
        manager.pairWithClientPin(server, clientPin: "3333")
        let filed = await requestFiled("3333")
        XCTAssertTrue(filed)
        manager.cancelApproval(id)
        XCTAssertNil(manager.approvalPolls[id])
        XCTAssertNil(attempt, "the phase is back to nothing")
        XCTAssertEqual(manager.get(id)?.state, .idle)
        let stopped = await pollsHaveStopped()
        XCTAssertTrue(stopped, "no poll after the cancel")
        satellite.approveClientPin()
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertNil(store.sharedKey(for: id), "a late approval finds nobody polling")
        XCTAssertEqual(pairingFailures, [])
    }

    func testCancelAfterTheApprovalLeavesTheOpeningSessionAlone() async {
        manager.pairWithClientPin(server, clientPin: "6060")
        let filed = await requestFiled("6060")
        XCTAssertTrue(filed)
        satellite.holdNextSessionPut = true
        satellite.approveClientPin()
        let opening = await waitUntil { self.satellite.heldSessionPutCount >= 1 }
        XCTAssertTrue(opening)
        XCTAssertEqual(attempt?.phase, .approved)
        manager.cancelApproval(id)
        satellite.releaseHeldSessionPut()
        let live = await waitUntil { self.manager.get(self.id)?.state == .live }
        XCTAssertTrue(live, "the approval already handed off to the session")
    }

    func testCancelWithNoAttemptLeavesAnOpeningSessionAlone() async {
        satellite.pairingKeyHex = String(repeating: "1f", count: 32)
        store.setSharedKey(String(repeating: "1f", count: 32), for: id)
        satellite.holdNextSessionPut = true
        manager.connect(to: server)
        let opening = await waitUntil { self.satellite.heldSessionPutCount >= 1 }
        XCTAssertTrue(opening)
        manager.cancelApproval(id)
        satellite.releaseHeldSessionPut()
        let live = await waitUntil { self.manager.get(self.id)?.state == .live }
        XCTAssertTrue(live, "a cancel with no card open touches nothing")
    }

    // MARK: - The typed PIN

    func testAWrongPinIsARejectionTheAttemptCounts() async {
        manager.pairWithClientPin(server, clientPin: "2020")
        manager.pairWithPin(server, pin: "0000")
        XCTAssertEqual(attempt?.submittingPin, true)
        let first = await waitUntil { self.attempt?.rejections == 1 }
        XCTAssertTrue(first)
        XCTAssertEqual(attempt?.rejection, .wrongPin)
        XCTAssertEqual(attempt?.submittingPin, false)
        XCTAssertEqual(attempt?.phase, .awaiting, "the operator request keeps running beside it")
        manager.pairWithPin(server, pin: "9999")
        XCTAssertNil(attempt?.rejection, "a new submission clears the last error")
        let second = await waitUntil { self.attempt?.rejections == 2 }
        XCTAssertTrue(second)
        XCTAssertEqual(pairingFailures.count, 2)
    }

    func testAPendingAnswerToThePinIsItsOwnRejection() async {
        satellite.answerPinWithPending = true
        manager.pairWithPin(server, pin: "4321")
        let rejected = await waitUntil { self.attempt?.rejection == .pending }
        XCTAssertTrue(rejected)
    }

    func testAnUnreachableSatelliteRejectsThePin() async throws {
        let closedPort = try XCTUnwrap(ports)
        satellite.stop()
        let gone = DiscoveredServer(name: "Gone", ip: "127.0.0.1", udpPort: Int(closedPort.udp), pairPort: Int(closedPort.rest))
        manager.pairWithPin(gone, pin: "1234")
        let rejected = await waitUntil { self.manager.pairingAttempts.state[gone.id]?.rejection == .unreachable }
        XCTAssertTrue(rejected)
    }

    func testAVersionMismatchRejectsThePin() async {
        satellite.protocolRange = 4 ... 5
        manager.pairWithPin(server, pin: satellite.operatorPin)
        let rejected = await waitUntil { self.attempt?.rejection == .versionMismatch }
        XCTAssertTrue(rejected)
        XCTAssertEqual(pairingFailures, [.dishUpdateRequired])
    }

    func testAChangedIdentityRejectsThePin() async {
        store.setCertPin(host: "127.0.0.1", fingerprintHex: String(repeating: "00", count: 32))
        manager.pairWithPin(server, pin: satellite.operatorPin)
        let rejected = await waitUntil { self.attempt?.rejection == .identityChanged }
        XCTAssertTrue(rejected)
        XCTAssertEqual(pairingFailures, [.identityChanged])
    }

    // MARK: - First wins

    func testAPinPairingWinsAndStopsTheApprovalPoll() async {
        manager.pairWithClientPin(server, clientPin: "1212")
        let filed = await requestFiled("1212")
        XCTAssertTrue(filed)
        manager.pairWithPin(server, pin: satellite.operatorPin)
        let live = await waitUntil { self.manager.get(self.id)?.state == .live }
        XCTAssertTrue(live)
        XCTAssertNil(manager.approvalPolls[id], "the PIN pairing cancelled the poll")
        XCTAssertNil(attempt)
        let stopped = await pollsHaveStopped()
        XCTAssertTrue(stopped)
        XCTAssertEqual(store.sharedKey(for: id), satellite.pairingKeyHex)
    }

    func testAnApprovalWinsAndCancelsTheInFlightPinPairing() async {
        manager.pairWithClientPin(server, clientPin: "3434")
        let filed = await requestFiled("3434")
        XCTAssertTrue(filed)
        satellite.holdNextPair = true
        manager.pairWithPin(server, pin: satellite.operatorPin)
        let parked = await waitUntil { self.satellite.heldPairCount >= 1 }
        XCTAssertTrue(parked)
        satellite.approveClientPin()
        let live = await waitUntil { self.manager.get(self.id)?.state == .live }
        XCTAssertTrue(live)
        XCTAssertNil(manager.pinSubmissions[id], "the approval cancelled the typed PIN")
        let approvedKey = store.sharedKey(for: id)
        satellite.releaseHeldPair()
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(store.sharedKey(for: id), approvedKey, "the late PIN answer adopts nothing")
        XCTAssertEqual(manager.get(id)?.state, .live)
        XCTAssertEqual(pairingFailures, [])
    }
}
