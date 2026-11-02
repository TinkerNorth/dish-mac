// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import XCTest

/// The bench paces each producer to absolute deadlines: a late frame never
/// moves the next one, a rate that does not divide a second does not drift,
/// and a producer sleeps until shortly before a deadline and spins the rest.
final class PacingTests: XCTestCase {

    func testFrameKIsDueKPeriodsAfterTheStart() {
        let schedule = PaceSchedule(startNs: 1000, rateHz: 1000)
        XCTAssertEqual(schedule.deadline(0), 1000)
        XCTAssertEqual(schedule.deadline(1), 1_001_000)
        XCTAssertEqual(schedule.deadline(250), 250_001_000)
    }

    func testARateThatDoesNotDivideASecondDoesNotDrift() {
        let schedule = PaceSchedule(startNs: 0, rateHz: 3)
        XCTAssertEqual(schedule.deadline(1), 333_333_333)
        XCTAssertEqual(schedule.deadline(2), 666_666_666)
        XCTAssertEqual(schedule.deadline(3), 1_000_000_000, "the third frame lands on the second exactly")
        XCTAssertEqual(schedule.deadline(3000), 1000 * 1_000_000_000)
    }

    func testTheFramesDueInARunAreItsLengthTimesTheRate() {
        XCTAssertEqual(PaceSchedule(startNs: 0, rateHz: 1000).frames(within: 3_000_000_000), 3000)
        XCTAssertEqual(PaceSchedule(startNs: 0, rateHz: 250).frames(within: 200_000_000), 50)
    }

    func testAProducerSleepsUntilTheSpinWindowAndSpinsInsideIt() {
        XCTAssertEqual(sleepBeforeSpin(nowNs: 0, deadlineNs: 5_000_000, spinNs: 1_000_000), 4_000_000)
        XCTAssertNil(sleepBeforeSpin(nowNs: 4_500_000, deadlineNs: 5_000_000, spinNs: 1_000_000))
        XCTAssertNil(sleepBeforeSpin(nowNs: 6_000_000, deadlineNs: 5_000_000, spinNs: 1_000_000), "a missed deadline is spun past at once")
        XCTAssertNil(sleepBeforeSpin(nowNs: 0, deadlineNs: 500_000, spinNs: 1_000_000), "a deadline closer than the window is spun to")
    }

    func testAProducerOnItsDeadlinesKeepsThePace() {
        let schedule = PaceSchedule(startNs: 0, rateHz: 1000)
        let stamps = (0 ..< 100).map { schedule.deadline(UInt64($0)) + 10000 }
        let check = PacingCheck(stampsNs: stamps, schedule: schedule)
        XCTAssertEqual(check.early, 0)
        XCTAssertEqual(check.medianLateNs, 10000)
        XCTAssertTrue(check.kept)
    }

    func testAFrameBeforeItsDeadlineMeansThePacerWasNotApplied() {
        let schedule = PaceSchedule(startNs: 1_000_000, rateHz: 1000)
        var stamps = (0 ..< 10).map { schedule.deadline(UInt64($0)) }
        stamps[4] -= 1
        let check = PacingCheck(stampsNs: stamps, schedule: schedule)
        XCTAssertEqual(check.early, 1)
        XCTAssertFalse(check.kept)
    }

    func testAMedianFrameMoreThanAMillisecondLateFailsThePace() {
        let schedule = PaceSchedule(startNs: 0, rateHz: 1000)
        let stamps = (0 ..< 10).map { schedule.deadline(UInt64($0)) + 2_000_000 }
        let check = PacingCheck(stampsNs: stamps, schedule: schedule)
        XCTAssertEqual(check.medianLateNs, 2_000_000)
        XCTAssertFalse(check.kept)
    }
}
