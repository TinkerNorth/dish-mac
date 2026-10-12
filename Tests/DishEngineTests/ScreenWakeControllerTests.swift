// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishKernel
import XCTest
@testable import DishEngine

/// The wake controller against a fake inhibitor: the IOKit one needs a
/// display the CI host has not got.
final class ScreenWakeControllerTests: XCTestCase {

    final class FakeInhibitor: DisplaySleepInhibitor {
        private(set) var acquires = 0
        private(set) var releases = 0
        private(set) var lastReason: String?
        var isHeld = false

        func acquire(reason: String) {
            lastReason = reason
            if !isHeld {
                acquires += 1
                isHeld = true
            }
        }

        func release() {
            if isHeld {
                releases += 1
                isHeld = false
            }
        }
    }

    private var count: StateSource<Int>!
    private var fake: FakeInhibitor!
    private var controller: ScreenWakeController!

    override func setUp() {
        super.setUp()
        count = StateSource(initial: 0)
        fake = FakeInhibitor()
        controller = ScreenWakeController(upstream: count.statePublisher, inhibitor: fake, reason: "test reason")
        controller.start()
    }

    // MARK: - The pure count

    func testStreamingCountZeroWhenNothingBound() {
        XCTAssertEqual(ScreenWakeController.streamingCount(bindings: [:], connectionStates: ["a": .connected]), 0)
    }

    func testStreamingCountIgnoresBindingsToOfflineOrConnectingConnections() {
        let count = ScreenWakeController.streamingCount(
            bindings: ["slot-a": "conn-1", "slot-b": "conn-2", "slot-c": "conn-3"],
            connectionStates: ["conn-1": .saved, "conn-2": .connecting, "conn-3": .connected]
        )
        XCTAssertEqual(count, 1)
    }

    func testStreamingCountCountsUnsteadyLinksAsStreaming() {
        let count = ScreenWakeController.streamingCount(
            bindings: ["a": "c1", "b": "c2"],
            connectionStates: ["c1": .unstable, "c2": .connected]
        )
        XCTAssertEqual(count, 2)
    }

    func testStreamingCountIgnoresUnknownConnection() {
        XCTAssertEqual(ScreenWakeController.streamingCount(bindings: ["a": "missing"], connectionStates: [:]), 0)
    }

    func testStreamingSlotCountFromSummaries() {
        let summaries = [
            ConnectionSummary(id: "c1", label: "", detail: "", live: .connected, boundSlotId: "a"),
            ConnectionSummary(id: "c2", label: "", detail: "", live: .saved, boundSlotId: "b")
        ]
        XCTAssertEqual(streamingSlotCount(bindings: ["a": "c1", "b": "c2"], summaries: summaries), 1)
    }

    // MARK: - The inhibitor follows the count

    func testStartingWithNothingStreamingHoldsNothing() {
        XCTAssertEqual(fake.acquires, 0)
        XCTAssertFalse(fake.isHeld)
    }

    func testFirstStreamAcquiresTheInhibitorWithTheReason() {
        count.setState(1)
        XCTAssertEqual(fake.acquires, 1)
        XCTAssertEqual(fake.releases, 0)
        XCTAssertEqual(fake.lastReason, "test reason")
        XCTAssertTrue(fake.isHeld)
    }

    func testGoingFromOneToTwoSlotsDoesNotReacquire() {
        count.setState(1)
        count.setState(2)
        XCTAssertEqual(fake.acquires, 1)
    }

    func testDroppingToZeroReleases() {
        count.setState(2)
        count.setState(0)
        XCTAssertEqual(fake.acquires, 1)
        XCTAssertEqual(fake.releases, 1)
        XCTAssertFalse(fake.isHeld)
    }

    func testReacquiresAfterADrop() {
        count.setState(1)
        count.setState(0)
        count.setState(1)
        XCTAssertEqual(fake.acquires, 2)
        XCTAssertEqual(fake.releases, 1)
        XCTAssertTrue(fake.isHeld)
    }

    func testResetReleasesAndZerosTheCount() {
        count.setState(3)
        controller.reset()
        XCTAssertEqual(controller.streamingSlotCount, 0)
        XCTAssertEqual(fake.releases, 1)
        XCTAssertFalse(fake.isHeld)
    }

    func testAStoppedControllerIgnoresTheCount() {
        controller.stop()
        count.setState(1)
        XCTAssertEqual(fake.acquires, 0)
    }
}
