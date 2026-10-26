// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Combine
import DishCore
import XCTest
@testable import DishEngine

/// The setup walk through the composition root: it opens on Input or, for
/// a pad it was handed, on Destination; its draft is the one the type
/// picker and the apply read; nothing is written until Review's one apply;
/// an unplugged pad blocks it; leaving drops it. The page-open scan waits
/// until the Local Network prompt has been explained, and the explanation
/// is remembered.
@MainActor
final class AppModelSetupTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suite: String!
    private var store: ConnectionStore!
    private var moonlight: MoonlightConnectionManager!
    private var model: AppModel!

    private let host = MoonlightHost(name: "PC", address: "10.0.0.5", uniqueId: "abc")
    private let pad = GameControllerInput.Slot(id: "pad", name: "DualSense", capabilities: .none, battery: nil, family: .dualSense)

    override func setUp() {
        super.setUp()
        suite = "dish.test.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        store = ConnectionStore(defaults: defaults, keyStore: InMemoryKeyStore())
        model = makeModel()
        model.input.slots = [pad]
    }

    override func tearDown() {
        model = nil
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    /// A sweep that hears nothing, slow enough for a test to see it run.
    private static let aQuietLAN: @Sendable () async -> WifiConnectionManager.ScanResult = {
        try? await Task.sleep(nanoseconds: 200_000_000)
        return WifiConnectionManager.ScanResult(broadcast: [], mdns: [])
    }

    private func makeModel() -> AppModel {
        moonlight = MoonlightConnectionManager(
            store: MoonlightHostStore(defaults: defaults),
            gateway: ScriptedMoonlightGateway(),
            identity: nil,
            edges: FakeMoonlightEdges(),
            discover: { [] }
        )
        return AppModel(
            store: store,
            defaults: defaults,
            moonlight: moonlight,
            discovery: WifiConnectionManager.DiscoveryPaths(scan: Self.aQuietLAN)
        )
    }

    private var walk: SetupWizardState? {
        model.shellFacts.setup
    }

    private func rememberHost() {
        moonlight.store.put(RememberedMoonlightHost(host: host, paired: true))
        moonlight.publishRemembered()
    }

    // MARK: - Opening

    func testTheWalkOpensOnInputWithNothingAnswered() {
        model.pageAppeared(.setup(seedSlotId: nil))
        XCTAssertEqual(walk, SetupWizardState())
        XCTAssertNil(model.shellFacts.binding.draft)
    }

    func testAPadHandedToTheWalkIsPreAnsweredAndItOpensOnDestination() {
        model.pageAppeared(.setup(seedSlotId: pad.id))
        XCTAssertEqual(walk?.step, .destination)
        XCTAssertEqual(walk?.draft?.slotId, pad.id)
        XCTAssertEqual(model.shellFacts.binding.draft, walk?.draft, "the type picker reads the walk's draft")
    }

    func testAPadThatIsNotAttachedIsNotASeed() {
        model.pageAppeared(.setup(seedSlotId: "gone"))
        XCTAssertEqual(walk?.step, .input)
        XCTAssertNil(walk?.draft)
    }

    func testLeavingTheWalkDropsItAndItsDraft() {
        model.pageAppeared(.setup(seedSlotId: pad.id))
        model.pageDisappeared(.setup(seedSlotId: pad.id))
        XCTAssertNil(walk)
        XCTAssertNil(model.shellFacts.binding.draft)
        XCTAssertNil(model.shellFacts.binding.candidate)
    }

    // MARK: - The walk

    func testPickingAPadSeedsTheDraftFromItsSwitches() {
        model.setSlotSwitch(.rumble, on: false, slotId: pad.id)
        model.pageAppeared(.setup(seedSlotId: nil))
        model.pickSetupPad(pad.id)
        XCTAssertEqual(walk?.draft?.current.rumble, false)
        XCTAssertEqual(model.shellFacts.binding.draft, walk?.draft)
        model.pickSetupPad("gone")
        XCTAssertEqual(walk?.draft?.slotId, pad.id, "a pad that is not attached is not picked")
    }

    func testAMoonlightHostAsksForTheSessionAndReviewIsTheOneWrite() {
        rememberHost()
        model.pageAppeared(.setup(seedSlotId: nil))
        model.pickSetupPad(pad.id)
        model.setupNext()
        model.pickSetupDestination(host.id)
        model.setupNext()
        model.editSetup(.setMotion(false))
        XCTAssertEqual(walk?.step, .type)
        model.setupNext()
        XCTAssertEqual(walk?.step, .session)
        model.setupNext()
        model.setupNext()
        XCTAssertEqual(walk?.step, .review)
        XCTAssertNil(model.hub.bindings[pad.id], "nothing is written before Review")
        XCTAssertTrue(model.slotPreferences.preferences(for: pad.id).motion)
        model.setupNext()
        XCTAssertEqual(model.shellFacts.binding.progress, .done)
        XCTAssertEqual(model.hub.bindings[pad.id], host.id)
        XCTAssertFalse(model.slotPreferences.preferences(for: pad.id).motion)
        XCTAssertEqual(walk?.applied, true, "the walk learns that its apply landed")
    }

    func testBackAndStartOverAreTheWalksOwn() {
        model.pageAppeared(.setup(seedSlotId: pad.id))
        model.setupBack()
        XCTAssertEqual(walk?.step, .input)
        model.startSetupOver()
        XCTAssertEqual(walk, SetupWizardState())
        XCTAssertNil(model.shellFacts.binding.draft)
    }

    func testUnpluggingThePickedPadBlocksTheWalkAndPluggingItBackClearsIt() {
        model.pageAppeared(.setup(seedSlotId: pad.id))
        model.input.slots = []
        XCTAssertEqual(walk?.blocker, .controllerUnplugged)
        model.input.slots = [pad]
        XCTAssertNil(walk?.blocker)
    }

    // MARK: - Explaining the Local Network prompt

    func testThePageOpenScanWaitsUntilThePromptIsExplained() {
        XCTAssertFalse(model.shellFacts.connections.localNetworkPrimed)
        model.pageAppeared(.connections)
        XCTAssertFalse(model.wifi.isScanning, "no prompt before the card has said why")
        model.primeLocalNetwork()
        XCTAssertTrue(model.wifi.isScanning, "Show me the prompt runs the scan")
        XCTAssertTrue(model.shellFacts.connections.localNetworkPrimed)
        XCTAssertTrue(store.onboarding.localNetworkPrimed)
    }

    func testTheScanButtonNeedsNoExplainingAfterwards() {
        model.startScan()
        XCTAssertTrue(model.shellFacts.connections.localNetworkPrimed)
    }

    func testTheExplanationIsRememberedAcrossALaunch() {
        model.primeLocalNetwork()
        model = makeModel()
        XCTAssertTrue(model.shellFacts.connections.localNetworkPrimed)
        model.pageAppeared(.connections)
        XCTAssertTrue(model.wifi.isScanning, "a primed page scans as it opens")
    }

    func testTheWalksDestinationScansOnlyOnceThePromptIsExplained() {
        model.pageAppeared(.setup(seedSlotId: pad.id))
        XCTAssertFalse(model.wifi.isScanning)
        model.setupBack()
        model.primeLocalNetwork()
        let scanned = model.wifi.isScanning
        XCTAssertTrue(scanned)
    }

    func testAPrimedWalkScansAsDestinationComesUp() {
        model.primeLocalNetwork()
        model = makeModel()
        model.input.slots = [pad]
        model.pageAppeared(.setup(seedSlotId: nil))
        model.pickSetupPad(pad.id)
        XCTAssertFalse(model.wifi.isScanning)
        model.setupNext()
        XCTAssertTrue(model.wifi.isScanning, "entering Destination looks for hosts")
    }
}
