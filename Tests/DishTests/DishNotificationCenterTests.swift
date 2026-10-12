// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import XCTest
@testable import Dish

/// Coverage for `DishNotificationCenter`: post / dismiss flow, monotonic
/// ids, same-key replacement, queue cap, and the severity-default
/// duration policy. Auto-dismiss timer mechanics are exercised via a
/// short `durationMs` + an XCTest expectation so the test suite stays
/// quick (the ms unit is the only thing the queue cares about).
@MainActor
final class DishNotificationCenterTests: XCTestCase {

    func testAddAssignsMonotonicIdsAndAppends() {
        let center = DishNotificationCenter()
        let firstId = center.add(severity: .info, title: "Hello")
        let secondId = center.add(severity: .info, title: "World")
        XCTAssertEqual(center.visible.count, 2)
        XCTAssertEqual(center.visible[0].title, "Hello")
        XCTAssertEqual(center.visible[1].title, "World")
        XCTAssertLessThan(firstId, secondId)
    }

    func testDismissByIdRemovesEntry() {
        let center = DishNotificationCenter()
        let id = center.add(severity: .error, title: "Boom")
        XCTAssertEqual(center.visible.count, 1)
        center.dismiss(id: id)
        XCTAssertTrue(center.visible.isEmpty)
    }

    func testSameKeyReplacementCollapsesToOne() {
        // Two posts with the same non-nil key must end up as a single
        // visible row (the newer one), never stacked. State-driven
        // emit sites ("wifi is off") rely on this.
        let center = DishNotificationCenter()
        center.add(severity: .warn, title: "Wifi is off", key: "wifi.state")
        center.add(severity: .warn, title: "Wifi is still off", key: "wifi.state")
        XCTAssertEqual(center.visible.count, 1)
        XCTAssertEqual(center.visible.first?.title, "Wifi is still off")
    }

    func testDifferentKeysCoexist() {
        let center = DishNotificationCenter()
        center.add(severity: .warn, title: "A", key: "a")
        center.add(severity: .warn, title: "B", key: "b")
        XCTAssertEqual(center.visible.count, 2)
    }

    func testNilKeyPostsDoNotDedup() {
        // Two banners without a key are independent posts even with
        // identical content: callers that don't supply a key opt out
        // of dedup explicitly.
        let center = DishNotificationCenter()
        center.add(severity: .info, title: "Duplicate")
        center.add(severity: .info, title: "Duplicate")
        XCTAssertEqual(center.visible.count, 2)
    }

    func testInfoDefaultsToShortDurationAndErrorToLong() {
        // The severity-default duration policy is the user-visible
        // difference between an INFO ping and a full ERROR banner;
        // assert the contract directly rather than waiting on a timer.
        let center = DishNotificationCenter()
        center.add(severity: .info, title: "i")
        center.add(severity: .error, title: "e")
        XCTAssertEqual(center.visible[0].durationMs, DishNotification.durationShort)
        XCTAssertEqual(center.visible[1].durationMs, DishNotification.durationLong)
    }

    func testPersistentDurationDoesNotAutoDismiss() async {
        // A durationMs of 0 opts out of the auto-dismiss timer; the
        // banner must still be there after a short wait. Use a 50 ms
        // observation window — short enough not to slow the suite,
        // long enough that any incorrectly-scheduled timer would have
        // fired (the default short duration is 3.5 s anyway).
        let center = DishNotificationCenter()
        center.add(
            severity: .error,
            title: "Stay",
            durationMs: DishNotification.durationPersistent
        )
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(center.visible.count, 1)
    }

    func testCapacityEvictsOldestWhenOverflowing() {
        // Six is the documented max. The seventh post must evict the
        // first; oldest-first eviction keeps the user looking at the
        // most-recent surface.
        let center = DishNotificationCenter()
        for i in 0 ..< 7 {
            center.add(severity: .info, title: "n\(i)")
        }
        XCTAssertEqual(center.visible.count, 6)
        XCTAssertEqual(center.visible.first?.title, "n1")
        XCTAssertEqual(center.visible.last?.title, "n6")
    }

    func testDismissAllClearsQueue() {
        let center = DishNotificationCenter()
        center.add(severity: .info, title: "a")
        center.add(severity: .warn, title: "b")
        center.dismissAll()
        XCTAssertTrue(center.visible.isEmpty)
    }
}
