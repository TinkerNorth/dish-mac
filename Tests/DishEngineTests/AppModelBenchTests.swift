// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import XCTest
@testable import DishEngine

/// The inspector's tests as the page reaches them: a feedback test runs from
/// the model on the live clock, the page sees it running, and once it has
/// ended the page asks; an audio test a pad cannot run asks nothing.
@MainActor
final class AppModelBenchTests: XCTestCase {

    private var defaults: UserDefaults!
    private var defaultsName: String!
    private var model: AppModel!

    override func setUpWithError() throws {
        try super.setUpWithError()
        defaultsName = "dish.test.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsName)
        model = AppModel(
            store: ConnectionStore(defaults: defaults, keyStore: InMemoryKeyStore()),
            defaults: defaults,
            hidCensus: FakeHidCensus(),
            discovery: WifiConnectionManager.DiscoveryPaths { WifiConnectionManager.ScanResult(broadcast: [], mdns: []) }
        )
    }

    override func tearDown() {
        model = nil
        defaults.removePersistentDomain(forName: defaultsName)
        super.tearDown()
    }

    private func waitUntil(timeout: TimeInterval = 3, _ predicate: @escaping () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() {
                return true
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return predicate()
    }

    func testAFeedbackTestRunsFromTheModelAndThePageAsksOnceItHasEnded() async {
        model.runFeedbackTest(.rumble(.weak), slotId: "pad")
        XCTAssertEqual(model.shellFacts.benchRuns, ["pad": .rumble(.weak)])
        XCTAssertNil(model.shellFacts.outcomes.asking("pad"), "no question while it runs")
        let asked = await waitUntil { self.model.shellFacts.outcomes.asking("pad")?.test == .rumbleWeak }
        XCTAssertTrue(asked)
        XCTAssertEqual(model.shellFacts.benchRuns, [:])
        model.answerTestOutcome(slotId: "pad", worked: true)
        XCTAssertEqual(model.shellFacts.outcomes.answers("pad").map(\.test), [.rumbleWeak])
    }

    func testAnAudioTestAPadCannotRunAsksNothing() {
        model.playTestTone(slotId: "pad")
        model.playHapticsTone(slotId: "pad")
        model.startMicMeter(slotId: "pad")
        XCTAssertEqual(model.shellFacts.outcomes, PadOutcomes())
    }
}
