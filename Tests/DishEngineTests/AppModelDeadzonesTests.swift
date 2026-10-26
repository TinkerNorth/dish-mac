// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import XCTest
@testable import DishEngine

/// The dead zones through the composition root: an attached pad gets the
/// zones stored for it, a pad never tuned gets the defaults, a change on the
/// Dead zones page reaches the pad at once, a reset brings the defaults
/// back, and the page reads what is stored from the shell's facts.
@MainActor
final class AppModelDeadzonesTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suite: String!
    private var model: AppModel!
    private var sent: [GamepadReport] = []
    private let pad = GameControllerInput.Slot(id: "pad", name: "DualSense", capabilities: .none, battery: nil, family: .dualSense)

    override func setUp() {
        super.setUp()
        suite = "dish.test.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        sent = []
    }

    override func tearDown() {
        model = nil
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func makeModel() {
        model = AppModel(store: ConnectionStore(defaults: defaults, keyStore: InMemoryKeyStore()), defaults: defaults)
        model.input.processor.reportSender = { [weak self] _, report in self?.sent.append(report) }
    }

    /// A stick pushed `lx` across, as the pad would report it.
    private func push(_ lx: Int16) {
        var report = GamepadReport()
        report.lx = lx
        model.input.processor.publish(deviceId: pad.id, state: report)
    }

    func testAnAttachedPadReceivesTheZonesStoredForIt() {
        defaults.set(#"{"s":6554,"t":26}"#, forKey: "deadzone:pad")
        makeModel()
        model.input.slots = [pad]
        push(5000)
        XCTAssertEqual(sent.last?.lx, 0, "5000 is inside the stored 20 % flat")
    }

    func testAPadNeverTunedGetsTheDefaults() {
        makeModel()
        model.input.slots = [pad]
        push(3000)
        XCTAssertEqual(sent.last?.lx, 0, "3000 is inside the default 10 % flat")
        push(5000)
        XCTAssertEqual(sent.last?.lx, 5000, "5000 is outside it")
    }

    func testAChangedZoneReachesTheAttachedPadAtOnce() {
        makeModel()
        model.input.slots = [pad]
        model.setStickDeadzone(percent: 20, slotId: pad.id)
        push(5000)
        XCTAssertEqual(sent.last?.lx, 0)
        XCTAssertEqual(defaults.string(forKey: "deadzone:pad"), #"{"s":6553,"t":13}"#, "the trigger keeps its flat")
    }

    func testATriggerChangeKeepsTheStick() {
        makeModel()
        model.setTriggerDeadzone(percent: 0, slotId: pad.id)
        XCTAssertEqual(model.shellFacts.deadzones["pad"], DeadzoneSetting(stickFlat: 3277, triggerFlat: 0))
    }

    func testAResetBringsTheDefaultsBack() {
        makeModel()
        model.input.slots = [pad]
        model.setStickDeadzone(percent: 0, slotId: pad.id)
        push(1000)
        XCTAssertEqual(sent.last?.lx, 1000, "no flat lets a small push through")
        model.resetDeadzones(slotId: pad.id)
        push(1000)
        XCTAssertEqual(sent.last?.lx, 0, "the default flat is back")
        XCTAssertNil(model.shellFacts.deadzones["pad"])
    }

    func testThePageReadsWhatIsStoredFromTheFacts() {
        defaults.set(#"{"s":6554,"t":26}"#, forKey: "deadzone:pad")
        makeModel()
        XCTAssertEqual(model.shellFacts.deadzones, ["pad": DeadzoneSetting(stickFlat: 6554, triggerFlat: 26)])
    }
}
