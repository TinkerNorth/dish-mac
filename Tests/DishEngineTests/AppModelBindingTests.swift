// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Combine
import DishCore
import XCTest
@testable import DishEngine

/// The Configure binding page through the composition root: opening it
/// seeds a draft from the binding and the switches, an edit changes the
/// draft and nothing else, the one apply writes the binding, the type and
/// the switches together, a Moonlight binding is done at once, a satellite
/// without a session waits for its link and may be cancelled back to what
/// was there, a pad that left fails the apply, and leaving the page drops
/// the draft.
@MainActor
final class AppModelBindingTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suite: String!
    private var store: ConnectionStore!
    private var moonlight: MoonlightConnectionManager!
    private var model: AppModel!

    private let den = DiscoveredServer(name: "Den", ip: "192.0.2.10", machineId: "den")
    private let host = MoonlightHost(name: "PC", address: "10.0.0.5", uniqueId: "abc")
    private let pad = GameControllerInput.Slot(id: "pad", name: "DualSense", capabilities: .none, battery: nil, family: .dualSense)

    override func setUp() {
        super.setUp()
        suite = "dish.test.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        store = ConnectionStore(defaults: defaults, keyStore: InMemoryKeyStore())
        moonlight = MoonlightConnectionManager(
            store: MoonlightHostStore(defaults: defaults),
            gateway: ScriptedMoonlightGateway(),
            identity: nil,
            edges: FakeMoonlightEdges(),
            discover: { [] }
        )
        model = AppModel(store: store, defaults: defaults, moonlight: moonlight)
        model.input.slots = [pad]
    }

    override func tearDown() {
        model = nil
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private var facts: BindingFacts {
        model.shellFacts.binding
    }

    private func rememberHost() {
        moonlight.store.put(RememberedMoonlightHost(host: host, paired: true))
        moonlight.publishRemembered()
    }

    private func rememberDen() {
        store.remember(den)
        model.wifi.register(WifiConnection(id: den.id, server: den, tickIntervalNs: .max))
    }

    private func waitUntil(timeout: TimeInterval = 5, _ predicate: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return predicate()
    }

    private func open() {
        model.pageAppeared(.configureBinding(slotId: pad.id))
    }

    // MARK: - The draft

    func testOpeningThePageSeedsTheDraftFromTheBindingAndTheSwitches() {
        rememberHost()
        model.bind(slotId: pad.id, connectionId: host.id)
        model.setSlotSwitch(.rumble, on: false, slotId: pad.id)
        open()
        let seeded = BindingChoice(connectionId: host.id, emulatedType: nil, rumble: false)
        XCTAssertEqual(facts.draft, BindingDraft(slotId: pad.id, original: seeded))
        XCTAssertEqual(facts.progress, .idle)
    }

    func testTheSeedCarriesTheTypeTheUserPicked() {
        rememberHost()
        model.bind(slotId: pad.id, connectionId: host.id)
        model.setEmulatedType(slotId: pad.id, type: 2)
        open()
        XCTAssertEqual(facts.draft?.original.emulatedType, 2)
    }

    func testAnEditChangesTheDraftAndNothingElse() {
        open()
        model.editBinding(.setRumble(false))
        XCTAssertEqual(facts.draft?.current.rumble, false)
        XCTAssertTrue(model.slotPreferences.preferences(for: pad.id).rumble, "nothing is written before the apply")
    }

    func testTheCandidateFollowsTheDraftsDestination() {
        rememberHost()
        open()
        XCTAssertNil(facts.candidate?.boundConnectionId)
        model.editBinding(.chooseDestination(host.id))
        XCTAssertEqual(facts.candidate?.boundConnectionId, host.id)
        XCTAssertEqual(facts.candidate?.boundStatus?.kind, .moonlight)
        XCTAssertNotNil(facts.candidate?.typeFeatures, "a Moonlight type is known without a catalog")
    }

    func testLeavingThePageDropsTheDraft() {
        open()
        model.editBinding(.setMic(true))
        model.pageDisappeared(.configureBinding(slotId: pad.id))
        XCTAssertNil(facts.draft)
        XCTAssertNil(facts.candidate)
    }

    // MARK: - The one apply

    func testApplyingToAMoonlightHostWritesEverythingAndIsDoneAtOnce() throws {
        rememberHost()
        open()
        model.editBinding(.chooseDestination(host.id))
        model.editBinding(.chooseType(2))
        model.editBinding(.setMotion(false))
        model.editBinding(.setTouchpad(.off))
        let draft = try XCTUnwrap(facts.draft)
        model.applyBinding(draft)
        XCTAssertEqual(facts.progress, .done)
        XCTAssertEqual(model.hub.bindings[pad.id], host.id)
        XCTAssertEqual(model.wifi.typeOverrides.typeFor(SlotKey(connectionId: host.id, slotId: pad.id)), 2)
        let switches = model.slotPreferences.preferences(for: pad.id)
        XCTAssertFalse(switches.motion)
        XCTAssertEqual(switches.touchpad, .off)
        XCTAssertEqual(facts.draft.map(isDirty), false, "what was applied is the new baseline")
    }

    func testAutoClearsAnEarlierPick() throws {
        rememberHost()
        model.bind(slotId: pad.id, connectionId: host.id)
        model.setEmulatedType(slotId: pad.id, type: 2)
        open()
        model.editBinding(.chooseType(nil))
        try model.applyBinding(XCTUnwrap(facts.draft))
        XCTAssertNil(model.wifi.typeOverrides.typeFor(SlotKey(connectionId: host.id, slotId: pad.id)))
    }

    func testASatelliteWithoutASessionWaitsForItsLinkAndCancelPutsEverythingBack() throws {
        rememberDen()
        open()
        model.editBinding(.chooseDestination(den.id))
        model.editBinding(.setRumble(false))
        try model.applyBinding(XCTUnwrap(facts.draft))
        XCTAssertEqual(facts.progress, .running(.binding))
        XCTAssertEqual(model.hub.bindings[pad.id], den.id, "the binding is written before the host is asked")
        XCTAssertNotEqual(model.wifi.connections[den.id]?.state, .idle, "the apply reaches for the host")
        model.cancelApply()
        XCTAssertEqual(facts.progress, .failed(.cancelled))
        XCTAssertNil(model.hub.bindings[pad.id], "the binding the page opened with is back")
        XCTAssertTrue(model.slotPreferences.preferences(for: pad.id).rumble)
        XCTAssertEqual(facts.draft.map(isDirty), true, "the draft is kept for another try")
    }

    /// A satellite in session, keyed so the connect goes straight to live.
    private func liveSatellite(_ satellite: FakeSatellite) async throws -> DiscoveredServer {
        let ports = try satellite.start()
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
        let live = await waitUntil { self.model.hub.summary(server.id)?.live == .connected }
        XCTAssertTrue(live, "the keyed connect reaches live")
        return server
    }

    func testASatelliteInSessionTakesThePutAndItsConfirmationLandsTheRun() async throws {
        let satellite = try FakeSatellite()
        defer { satellite.stop() }
        let server = try await liveSatellite(satellite)
        open()
        model.editBinding(.chooseDestination(server.id))
        try model.applyBinding(XCTUnwrap(facts.draft))
        XCTAssertEqual(facts.progress, .running(.applyingOnHost), "no wait for a link that is up")
        let landed = await waitUntil { self.facts.progress == .done }
        XCTAssertTrue(landed, "the host's confirmation ends the run")
        model.wifi.disconnect(id: server.id)
    }

    func testReapplyingWhereThePadIsBoundAsksTheHostAgain() async throws {
        let satellite = try FakeSatellite()
        defer { satellite.stop() }
        let server = try await liveSatellite(satellite)
        model.bind(slotId: pad.id, connectionId: server.id)
        let applied = await waitUntil { self.model.wifi.get(server.id)?.slotApplied == true }
        XCTAssertTrue(applied)
        open()
        try model.applyBinding(XCTUnwrap(facts.draft))
        let landed = await waitUntil { self.facts.progress == .done }
        XCTAssertTrue(landed, "an unchanged binding is sent again for the host to confirm")
        model.wifi.disconnect(id: server.id)
    }

    func testAPadThatLeftFailsTheApply() throws {
        rememberHost()
        open()
        model.editBinding(.chooseDestination(host.id))
        let draft = try XCTUnwrap(facts.draft)
        model.input.slots = []
        model.applyBinding(draft)
        XCTAssertEqual(facts.progress, .failed(.padGone))
        XCTAssertNil(model.hub.bindings[pad.id])
    }

    func testADraftWithoutADestinationIsNotApplied() throws {
        open()
        try model.applyBinding(XCTUnwrap(facts.draft))
        XCTAssertEqual(facts.progress, .idle)
    }

    func testDismissingAnEndedApplyClearsTheOverlay() throws {
        rememberHost()
        open()
        model.editBinding(.chooseDestination(host.id))
        try model.applyBinding(XCTUnwrap(facts.draft))
        model.dismissApply()
        XCTAssertEqual(facts.progress, .idle)
    }

    func testUnbindingFromThePageReleasesThePadAndReseedsTheDraft() {
        rememberHost()
        model.bind(slotId: pad.id, connectionId: host.id)
        open()
        model.unbindFromDraft()
        XCTAssertNil(model.hub.bindings[pad.id])
        XCTAssertNil(facts.draft?.original.connectionId)
        XCTAssertEqual(facts.draft.map(isDirty), false)
    }

    func testTheGlobalSwitchesReachTheShellFacts() async {
        model.settings.motionEnabled = false
        let drawn = await waitUntil { self.model.shellFacts.forwarding.motion == false }
        XCTAssertTrue(drawn, "the pages fold the global switches from the facts")
    }
}

/// The apply's watch on its own: the budget ends a run the host never
/// answered, and a run that ended stops its clock.
@MainActor
final class BindingApplyWatchTests: XCTestCase {

    func testTheBudgetEndsARunTheHostNeverAnswered() async {
        let watch = BindingApplyWatch(budgetNs: 50_000_000)
        var heard: [ApplyEvent] = []
        watch.begin(sources: [], onEvent: { heard.append($0) })
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(heard, [.budgetSpent])
    }

    func testEndingARunStopsItsClock() async {
        let watch = BindingApplyWatch(budgetNs: 50_000_000)
        var heard: [ApplyEvent] = []
        watch.begin(sources: [], onEvent: { heard.append($0) })
        watch.end()
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(heard, [])
    }

    func testTheSourcesWordsReachTheRun() {
        let watch = BindingApplyWatch(budgetNs: 5_000_000_000)
        let words = PassthroughSubject<ApplyEvent, Never>()
        var heard: [ApplyEvent] = []
        watch.begin(sources: [words.eraseToAnyPublisher()], onEvent: { heard.append($0) })
        words.send(.hostConfirmed)
        watch.end()
        words.send(.hostRejected)
        XCTAssertEqual(heard, [.hostConfirmed], "an ended run hears nothing")
    }
}
