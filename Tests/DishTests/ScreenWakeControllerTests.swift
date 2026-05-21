// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import XCTest
@testable import Dish

/// Pins the `ScreenWakeController` contract — the macOS sibling of Android's
/// `WakeStateControllerTest`. The IOKit-backed implementation can't run on a
/// CI host that has no display, so a fake inhibitor stands in.
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

    // MARK: - streamingCount (pure derivation)

    func testStreamingCountZeroWhenNothingBound() {
        let count = ScreenWakeController.streamingCount(
            bindings: [:],
            connectionStates: ["a": .connected]
        )
        XCTAssertEqual(count, 0)
    }

    func testStreamingCountIgnoresBindingsToOfflineOrConnectingConnections() {
        let count = ScreenWakeController.streamingCount(
            bindings: ["slot-a": "conn-1", "slot-b": "conn-2", "slot-c": "conn-3"],
            connectionStates: [
                "conn-1": .saved,
                "conn-2": .connecting,
                "conn-3": .connected
            ]
        )
        XCTAssertEqual(count, 1)
    }

    func testStreamingCountReflectsMultipleConnectedSlots() {
        let count = ScreenWakeController.streamingCount(
            bindings: ["a": "c1", "b": "c2", "c": "c3"],
            connectionStates: [
                "c1": .connected,
                "c2": .connected,
                "c3": .saved
            ]
        )
        XCTAssertEqual(count, 2)
    }

    func testStreamingCountIgnoresUnknownConnection() {
        let count = ScreenWakeController.streamingCount(
            bindings: ["a": "missing"],
            connectionStates: [:]
        )
        XCTAssertEqual(count, 0)
    }

    // MARK: - update() drives the inhibitor

    func testFirstStreamAcquiresInhibitor() {
        let fake = FakeInhibitor()
        let c = ScreenWakeController(inhibitor: fake, reason: "test reason")
        c.update(streamingSlotCount: 1)
        XCTAssertEqual(fake.acquires, 1)
        XCTAssertEqual(fake.releases, 0)
        XCTAssertEqual(fake.lastReason, "test reason")
        XCTAssertTrue(fake.isHeld)
    }

    func testGoingFromOneToTwoSlotsDoesNotReacquire() {
        let fake = FakeInhibitor()
        let c = ScreenWakeController(inhibitor: fake)
        c.update(streamingSlotCount: 1)
        c.update(streamingSlotCount: 2)
        XCTAssertEqual(fake.acquires, 1)
    }

    func testDroppingToZeroReleases() {
        let fake = FakeInhibitor()
        let c = ScreenWakeController(inhibitor: fake)
        c.update(streamingSlotCount: 2)
        c.update(streamingSlotCount: 0)
        XCTAssertEqual(fake.acquires, 1)
        XCTAssertEqual(fake.releases, 1)
        XCTAssertFalse(fake.isHeld)
    }

    func testStayingAtZeroIsIdempotent() {
        let fake = FakeInhibitor()
        let c = ScreenWakeController(inhibitor: fake)
        c.update(streamingSlotCount: 0)
        c.update(streamingSlotCount: 0)
        XCTAssertEqual(fake.acquires, 0)
        XCTAssertEqual(fake.releases, 0)
    }

    func testReacquiresAfterDrop() {
        let fake = FakeInhibitor()
        let c = ScreenWakeController(inhibitor: fake)
        c.update(streamingSlotCount: 1)
        c.update(streamingSlotCount: 0)
        c.update(streamingSlotCount: 1)
        XCTAssertEqual(fake.acquires, 2)
        XCTAssertEqual(fake.releases, 1)
        XCTAssertTrue(fake.isHeld)
    }

    func testResetReleasesAndZerosCount() {
        let fake = FakeInhibitor()
        let c = ScreenWakeController(inhibitor: fake)
        c.update(streamingSlotCount: 3)
        c.reset()
        XCTAssertEqual(c.streamingSlotCount, 0)
        XCTAssertEqual(fake.releases, 1)
        XCTAssertFalse(fake.isHeld)
    }
}
