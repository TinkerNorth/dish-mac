// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import XCTest
@testable import Dish

final class AtomicCounterTests: XCTestCase {

    func testIncrementAndGetReturnsPostIncrementValue() {
        let counter = AtomicCounter()
        XCTAssertEqual(counter.incrementAndGet(), 1)
        XCTAssertEqual(counter.incrementAndGet(), 2)
        XCTAssertEqual(counter.incrementAndGet(), 3)
    }

    func testResetReturnsToZero() {
        let counter = AtomicCounter()
        _ = counter.incrementAndGet()
        _ = counter.incrementAndGet()
        counter.reset()
        XCTAssertEqual(counter.incrementAndGet(), 1)
    }

    func testConcurrentIncrementsAreAtomic() {
        let counter = AtomicCounter()
        let iters = 10000
        let threads = 8
        let group = DispatchGroup()
        for _ in 0 ..< threads {
            DispatchQueue.global().async(group: group) {
                for _ in 0 ..< iters {
                    _ = counter.incrementAndGet()
                }
            }
        }
        group.wait()
        // Post-increment of final call equals total number of increments.
        XCTAssertEqual(counter.incrementAndGet(), UInt64(threads * iters + 1))
    }
}
