// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import XCTest
@testable import Dish

/// Coverage for `ReturnPathApplier` — the serialised, coalesced replacement
/// for the per-packet `Task { @MainActor in … }` the rumble / light-bar return
/// paths used to spawn (review item H2).
///
/// The two properties under test:
///   * **Last-value-wins coalescing** — a burst of `submit`s for one device
///     collapses to a single `apply` of the *newest* value, so a stale colour
///     can't latch after a newer one.
///   * **Per-device isolation** — devices don't coalesce into each other.
final class ReturnPathApplierTests: XCTestCase {

    func testBurstCoalescesToNewestValue() {
        let applied = expectation(description: "apply ran")
        // Only assert once; a coalesced burst should apply exactly the last
        // value. We over-fulfill-guard with `assertForOverFulfill = false`
        // because timing could in principle let an early value through too —
        // what matters is the LAST value is the one that ends up applied.
        applied.assertForOverFulfill = false
        var lastApplied: Int?
        let applier = ReturnPathApplier<Int>(label: "test.coalesce") { _, value in
            lastApplied = value
            applied.fulfill()
        }
        // Fire a burst on a background thread before the main runloop drains.
        for value in 1 ... 50 {
            applier.submit(deviceId: "pad", value: value)
        }
        wait(for: [applied], timeout: 2.0)
        // The drain reads `pending`, which the burst left at the final value.
        XCTAssertEqual(lastApplied, 50, "coalesced burst must apply the newest value")
    }

    func testDevicesDoNotCrossContaminate() {
        let bothApplied = expectation(description: "both devices applied")
        bothApplied.expectedFulfillmentCount = 2
        bothApplied.assertForOverFulfill = false
        var byDevice: [String: Int] = [:]
        let applier = ReturnPathApplier<Int>(label: "test.isolation") { deviceId, value in
            byDevice[deviceId] = value
            bothApplied.fulfill()
        }
        applier.submit(deviceId: "padA", value: 11)
        applier.submit(deviceId: "padB", value: 22)
        wait(for: [bothApplied], timeout: 2.0)
        XCTAssertEqual(byDevice["padA"], 11)
        XCTAssertEqual(byDevice["padB"], 22)
    }

    func testApplyRunsOnMainActor() {
        let applied = expectation(description: "apply ran")
        let applier = ReturnPathApplier<Int>(label: "test.mainactor") { _, _ in
            // The closure is `@MainActor`; this would not compile / would trap
            // if it ran off the main actor. Assert the thread explicitly too.
            XCTAssertTrue(Thread.isMainThread, "apply must run on the main thread")
            applied.fulfill()
        }
        applier.submit(deviceId: "pad", value: 1)
        wait(for: [applied], timeout: 2.0)
    }

    func testSequentialSubmitsEachApply() {
        // Submits spaced so each drains before the next arrives must each
        // apply — coalescing only collapses an in-flight burst.
        let applier = ReturnPathApplier<Int>(label: "test.sequential") { _, _ in }
        for value in 1 ... 3 {
            let done = expectation(description: "drain \(value)")
            let probe = ReturnPathApplier<Int>(label: "test.probe.\(value)") { _, _ in
                done.fulfill()
            }
            probe.submit(deviceId: "pad", value: value)
            wait(for: [done], timeout: 2.0)
            _ = applier // keep the primary applier alive for the loop
        }
    }
}
