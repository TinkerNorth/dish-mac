// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import XCTest
@testable import DishCore

/// The bench's buzz is dish-android's: 48000 for 400 ms, one motor or both.
final class FeedbackBenchTests: XCTestCase {

    func testTheWeakTestBuzzRunsOnlyTheWeakMotor() {
        XCTAssertEqual(testBuzz(for: .weak), TestBuzz(strong: 0, weak: 48000, durationMs: 400))
    }

    func testTheStrongTestBuzzRunsOnlyTheStrongMotor() {
        XCTAssertEqual(testBuzz(for: .strong), TestBuzz(strong: 48000, weak: 0, durationMs: 400))
    }

    func testTheCombinedTestBuzzRunsBothMotorsAtOnce() {
        XCTAssertEqual(testBuzz(for: .both), TestBuzz(strong: 48000, weak: 48000, durationMs: 400))
    }

    func testATestBuzzIsDishAndroids() {
        XCTAssertEqual(TestBuzz.magnitude, 48000)
        XCTAssertEqual(TestBuzz.durationMs, 400)
        XCTAssertEqual(BuzzMotor.allCases, [.weak, .strong, .both])
    }
}
