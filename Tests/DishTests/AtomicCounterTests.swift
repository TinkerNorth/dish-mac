// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import XCTest
@testable import Dish

final class AtomicCounterTests: XCTestCase {

    func testIncrementAndGetReturnsPostIncrementValue() {
        let c = AtomicCounter()
        XCTAssertEqual(c.incrementAndGet(), 1)
        XCTAssertEqual(c.incrementAndGet(), 2)
        XCTAssertEqual(c.incrementAndGet(), 3)
    }

    func testResetReturnsToZero() {
        let c = AtomicCounter()
        _ = c.incrementAndGet()
        _ = c.incrementAndGet()
        c.reset()
        XCTAssertEqual(c.incrementAndGet(), 1)
    }

    func testConcurrentIncrementsAreAtomic() {
        let c = AtomicCounter()
        let iters = 10_000
        let threads = 8
        let group = DispatchGroup()
        for _ in 0..<threads {
            DispatchQueue.global().async(group: group) {
                for _ in 0..<iters { _ = c.incrementAndGet() }
            }
        }
        group.wait()
        // Post-increment of final call equals total number of increments.
        XCTAssertEqual(c.incrementAndGet(), UInt64(threads * iters + 1))
    }
}
