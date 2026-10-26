// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import XCTest
@testable import DishEngine

/// The clock the words "last checked …" are read against: it reads the
/// stamp and the time as a page shows, ticks once a minute while one does,
/// stops with the last, and a completed check is read at once.
@MainActor
final class UpdateCheckClockTests: XCTestCase {

    private var lastCheckMs: Int64 = 0
    private var nowMs: Int64 = 1_700_000_000_000

    private func makeClock() -> UpdateCheckClock {
        UpdateCheckClock(lastCheckMs: { [self] in lastCheckMs }, now: { [self] in nowMs })
    }

    func testTheClockStartsOnTheStampAndTheTime() {
        lastCheckMs = 1_699_999_000_000
        XCTAssertEqual(makeClock().state, UpdateCheckTime(lastCheckMs: 1_699_999_000_000, nowMs: 1_700_000_000_000))
    }

    func testShowingReadsTheTimeAgain() {
        let clock = makeClock()
        nowMs += 120_000
        clock.show()
        XCTAssertEqual(clock.state.nowMs, 1_700_000_120_000)
    }

    func testTheClockTicksEveryMinuteWhileAPageShowsAndStopsWhenTheLastLeaves() {
        let clock = makeClock()
        XCTAssertEqual(UpdateCheckClock.tickSeconds, 60)
        XCTAssertFalse(clock.isTicking)
        clock.show()
        clock.show()
        XCTAssertTrue(clock.isTicking)
        clock.hide()
        XCTAssertTrue(clock.isTicking, "another page still shows")
        clock.hide()
        XCTAssertFalse(clock.isTicking)
        clock.hide()
        XCTAssertFalse(clock.isTicking, "an extra hide never goes below none")
    }

    func testARefreshReadsTheStampAndTheTime() {
        let clock = makeClock()
        lastCheckMs = 1_700_000_060_000
        nowMs = 1_700_000_090_000
        clock.refresh()
        XCTAssertEqual(clock.state, UpdateCheckTime(lastCheckMs: 1_700_000_060_000, nowMs: 1_700_000_090_000))
    }
}
