// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import DishKernel
import XCTest
@testable import DishEngine

/// The wake controller against a fake inhibitor: the IOKit one needs a
/// display the CI host has not got.
final class WakeStateControllerTests: XCTestCase {

    final class FakeInhibitor: WakeInhibitor {
        private(set) var holds: [KeepAwakeReach] = []
        private(set) var releases = 0
        private(set) var lastReason: String?
        private(set) var held: KeepAwakeReach = .none

        func hold(_ reach: KeepAwakeReach, reason: String) {
            lastReason = reason
            guard reach != held else { return }
            holds.append(reach)
            held = reach
        }

        func release() {
            if held != .none { releases += 1 }
            held = .none
        }
    }

    private var wake: StateSource<WakeState>!
    private var fake: FakeInhibitor!
    private var controller: WakeStateController!

    override func setUp() {
        super.setUp()
        wake = StateSource(initial: WakeState())
        fake = FakeInhibitor()
        controller = WakeStateController(upstream: wake.statePublisher, inhibitor: fake, reason: "test reason")
        controller.start()
    }

    // MARK: - The pure count

    func testStreamingCountZeroWhenNothingBound() {
        XCTAssertEqual(streamingCount(bindings: [:], connectionStates: ["a": .connected]), 0)
    }

    func testStreamingCountIgnoresOfflineOrConnectingConnections() {
        let count = streamingCount(
            bindings: ["slot-a": "conn-1", "slot-b": "conn-2", "slot-c": "conn-3"],
            connectionStates: ["conn-1": .saved, "conn-2": .connecting, "conn-3": .connected]
        )
        XCTAssertEqual(count, 1)
    }

    func testStreamingCountCountsUnsteadyLinksAsStreaming() {
        XCTAssertEqual(streamingCount(bindings: ["slot-a": "conn-1"], connectionStates: ["conn-1": .unstable]), 1)
    }

    func testStreamingSlotCountReadsTheSummaries() {
        let summaries = [
            ConnectionSummary(id: "c1", label: "", detail: "", live: .connected, boundSlotId: "a"),
            ConnectionSummary(id: "c2", label: "", detail: "", live: .saved, boundSlotId: "b")
        ]
        XCTAssertEqual(streamingSlotCount(bindings: ["a": "c1", "b": "c2"], summaries: summaries), 1)
    }

    // MARK: - The hold follows the reach

    func testStartingAppliesTheCurrentValueAtOnce() {
        let held = StateSource(initial: WakeState(reach: .system, streamingSlotCount: 1))
        let fresh = FakeInhibitor()
        let late = WakeStateController(upstream: held.statePublisher, inhibitor: fresh, reason: "late")
        XCTAssertEqual(fresh.held, .none, "nothing before start")
        late.start()
        XCTAssertEqual(fresh.held, .system)
        XCTAssertEqual(fresh.lastReason, "late")
    }

    func testTheReachMovesTheHoldAndNoneLetsGo() {
        wake.setState(WakeState(reach: .system, streamingSlotCount: 1))
        XCTAssertEqual(fake.held, .system)
        wake.setState(WakeState(reach: .systemAndDisplay, streamingSlotCount: 1))
        XCTAssertEqual(fake.held, .systemAndDisplay)
        XCTAssertEqual(fake.holds, [.system, .systemAndDisplay])
        wake.setState(WakeState(reach: .none, streamingSlotCount: 0))
        XCTAssertEqual(fake.held, .none)
        XCTAssertEqual(fake.releases, 1)
    }

    func testACountChangeAtTheSameReachDoesNotReHold() {
        wake.setState(WakeState(reach: .system, streamingSlotCount: 1))
        wake.setState(WakeState(reach: .system, streamingSlotCount: 2))
        XCTAssertEqual(fake.holds, [.system])
        XCTAssertEqual(controller.current.streamingSlotCount, 2)
    }

    func testStoppingLetsGoWhateverTheState() {
        wake.setState(WakeState(reach: .system, streamingSlotCount: 1))
        controller.stop()
        XCTAssertEqual(fake.held, .none)
        wake.setState(WakeState(reach: .systemAndDisplay, streamingSlotCount: 1))
        XCTAssertEqual(fake.held, .none, "a stopped controller applies nothing")
    }

    // MARK: - The IOKit mapping

    func testEachReachNamesItsAssertion() {
        XCTAssertNil(IOKitWakeInhibitor.assertionType(for: .none))
        XCTAssertEqual(IOKitWakeInhibitor.assertionType(for: .system), "PreventUserIdleSystemSleep")
        XCTAssertEqual(IOKitWakeInhibitor.assertionType(for: .systemAndDisplay), "PreventUserIdleDisplaySleep")
    }
}
