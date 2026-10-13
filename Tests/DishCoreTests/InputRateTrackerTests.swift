// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import XCTest
@testable import DishCore

/// The inspector's rate figure: quantized to 5 Hz, anchored by the first
/// sample, rebaselined by a counter that went backwards, held by a clock
/// that did not advance.
final class InputRateTrackerTests: XCTestCase {

    func testQuantizeRoundsToTheNearestMultipleOfFive() {
        XCTAssertEqual(quantizeHz(0), 0)
        XCTAssertEqual(quantizeHz(2.4), 0)
        XCTAssertEqual(quantizeHz(2.5), 5, "half away from zero")
        XCTAssertEqual(quantizeHz(22.5), 25)
        XCTAssertEqual(quantizeHz(123.4), 125)
        XCTAssertEqual(quantizeHz(7.6, step: 1), 8)
        XCTAssertEqual(quantizeHz(-3), 0, "never negative")
    }

    func testTheFirstSampleReportsZeroAndAnchors() {
        var tracker = InputRateTracker()
        XCTAssertEqual(tracker.sample(count: 100, nowUs: 1_000_000), 0)
        XCTAssertEqual(tracker.lastHz, 0)
    }

    func testTwoHundredEventsInOneSecondIsTwoHundredHertz() {
        var tracker = InputRateTracker()
        _ = tracker.sample(count: 0, nowUs: 0)
        XCTAssertEqual(tracker.sample(count: 200, nowUs: 1_000_000), 200)
    }

    func testAHalfSecondWindowDoublesTheRateAndARawRateIsQuantized() {
        var tracker = InputRateTracker()
        _ = tracker.sample(count: 0, nowUs: 0)
        XCTAssertEqual(tracker.sample(count: 100, nowUs: 500_000), 200)
        XCTAssertEqual(tracker.sample(count: 161, nowUs: 1_000_000), 120, "122 Hz reads as 120")
    }

    func testACounterGoingBackwardsReportsZeroAndRebaselines() {
        var tracker = InputRateTracker()
        _ = tracker.sample(count: 500, nowUs: 0)
        XCTAssertEqual(tracker.sample(count: 10, nowUs: 1_000_000), 0, "the device re-attached")
        XCTAssertEqual(tracker.sample(count: 110, nowUs: 2_000_000), 100)
    }

    func testASameInstantSampleHoldsTheLastRate() {
        var tracker = InputRateTracker()
        _ = tracker.sample(count: 0, nowUs: 0)
        XCTAssertEqual(tracker.sample(count: 50, nowUs: 1_000_000), 50)
        XCTAssertEqual(tracker.sample(count: 60, nowUs: 1_000_000), 50)
        XCTAssertEqual(tracker.sample(count: 110, nowUs: 2_000_000), 50, "measured from the re-anchored count")
    }

    func testNoEventsInTheWindowReportsZeroAndResetReAnchors() {
        var tracker = InputRateTracker()
        _ = tracker.sample(count: 0, nowUs: 0)
        XCTAssertEqual(tracker.sample(count: 0, nowUs: 1_000_000), 0)
        _ = tracker.sample(count: 100, nowUs: 2_000_000)
        tracker.reset()
        XCTAssertEqual(tracker.sample(count: 300, nowUs: 3_000_000), 0)
        XCTAssertEqual(tracker.lastHz, 0)
    }
}
