// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// The exponential reconnect-backoff schedule (contract/android/dish-linux
// parity: 1s, 2s, 4s, … capped at 60s) and the send-counter re-push guard.
// Pure — no clock, no timer. Ports dish-linux test_backoff.cpp.

import XCTest
import DishCore

final class BackoffTests: XCTestCase {

    func testBackoffDelayIsExponentialCappedAtSixtySeconds() {
        XCTAssertEqual(backoffDelayMs(attempt: 1), 1000) // 1s
        XCTAssertEqual(backoffDelayMs(attempt: 2), 2000) // 2s
        XCTAssertEqual(backoffDelayMs(attempt: 3), 4000) // 4s
        XCTAssertEqual(backoffDelayMs(attempt: 4), 8000) // 8s
        XCTAssertEqual(backoffDelayMs(attempt: 5), 16000) // 16s
        XCTAssertEqual(backoffDelayMs(attempt: 6), 32000) // 32s
        XCTAssertEqual(backoffDelayMs(attempt: 7), 60000) // 1000<<6 = 64000 → capped 60s
        XCTAssertEqual(backoffDelayMs(attempt: 8), 60000) // stays capped
        XCTAssertEqual(backoffDelayMs(attempt: 100), 60000)
    }

    func testBackoffDelayTreatsANonPositiveAttemptAsTheFirst() {
        XCTAssertEqual(backoffDelayMs(attempt: 0), 1000)
        XCTAssertEqual(backoffDelayMs(attempt: -5), 1000)
    }

    func testCounterNeedsRepushFiresOnceTheSendCounterCrossesTheThreshold() {
        XCTAssertFalse(counterNeedsRepush(1))
        XCTAssertFalse(counterNeedsRepush(0xEFFF_FFFF))
        XCTAssertTrue(counterNeedsRepush(0xF000_0000))
        XCTAssertTrue(counterNeedsRepush(0xFFFF_FFFF))
    }
}
