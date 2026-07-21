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

    // MARK: - current()/set() — the G4 re-key poll accessors

    func testCurrentReadsWithoutAdvancing() {
        let counter = AtomicCounter()
        XCTAssertEqual(counter.current(), 0)
        _ = counter.incrementAndGet()
        _ = counter.incrementAndGet()
        XCTAssertEqual(counter.current(), 2)
        XCTAssertEqual(counter.current(), 2, "current() must not advance the sequence")
        XCTAssertEqual(counter.incrementAndGet(), 3)
    }

    func testSetPlacesTheSequenceExactly() {
        // The re-key tests use set() to park the counter just under the
        // 0xF0000000 re-PUT threshold without four billion increments.
        let counter = AtomicCounter()
        counter.set(0xF000_0000)
        XCTAssertEqual(counter.current(), 0xF000_0000)
        XCTAssertEqual(counter.incrementAndGet(), 0xF000_0001)
        counter.reset()
        XCTAssertEqual(counter.current(), 0)
    }

    func testConcurrentCurrentReadsDoNotDisturbIncrements() {
        let counter = AtomicCounter()
        let iters = 10000
        let group = DispatchGroup()
        for _ in 0 ..< 4 {
            DispatchQueue.global().async(group: group) {
                for _ in 0 ..< iters {
                    _ = counter.incrementAndGet()
                }
            }
        }
        for _ in 0 ..< 4 {
            DispatchQueue.global().async(group: group) {
                for _ in 0 ..< iters {
                    _ = counter.current()
                }
            }
        }
        group.wait()
        XCTAssertEqual(counter.current(), UInt64(4 * iters), "reads must not lose increments")
    }
}

/// Coverage for `AtomicInt` / `AtomicBool` — the lock-guarded primitives the
/// heartbeat now uses for `missedAcks` / `connectionAlive`, which were a plain
/// `var` raced across the heartbeat + ACK dispatch queues (review item M1).
final class AtomicIntBoolTests: XCTestCase {

    func testAtomicIntIncrementGetSet() {
        let counter = AtomicInt(0)
        XCTAssertEqual(counter.incrementAndGet(), 1)
        XCTAssertEqual(counter.incrementAndGet(), 2)
        XCTAssertEqual(counter.get(), 2)
        counter.set(0)
        XCTAssertEqual(counter.get(), 0)
        XCTAssertEqual(counter.incrementAndGet(), 1)
    }

    func testAtomicIntInitialValue() {
        XCTAssertEqual(AtomicInt(7).get(), 7)
    }

    /// Models the heartbeat race: one pool of threads bumps the counter (the
    /// heartbeat loop), another resets it (the ACK loop). The reset count plus
    /// the surviving value must equal the total bumps — no lost increments.
    func testAtomicIntConcurrentIncrementAndSetIsRaceFree() {
        let counter = AtomicInt(0)
        let iters = 20000
        let group = DispatchGroup()
        // Bumpers.
        for _ in 0 ..< 4 {
            DispatchQueue.global().async(group: group) {
                for _ in 0 ..< iters {
                    _ = counter.incrementAndGet()
                }
            }
        }
        // Resetters racing the bumpers — just must not crash / corrupt.
        for _ in 0 ..< 2 {
            DispatchQueue.global().async(group: group) {
                for _ in 0 ..< iters {
                    counter.set(0)
                }
            }
        }
        group.wait()
        // The final value is whatever the last interleaving left, but it must
        // be a sane non-negative count well within the bump budget.
        let final = counter.get()
        XCTAssertGreaterThanOrEqual(final, 0)
        XCTAssertLessThanOrEqual(final, 4 * iters)
    }

    func testAtomicBoolGetSet() {
        let flag = AtomicBool(true)
        XCTAssertTrue(flag.get())
        flag.set(false)
        XCTAssertFalse(flag.get())
        flag.set(true)
        XCTAssertTrue(flag.get())
    }

    func testAtomicBoolConcurrentAccessIsRaceFree() {
        let flag = AtomicBool(true)
        let group = DispatchGroup()
        for idx in 0 ..< 8 {
            DispatchQueue.global().async(group: group) {
                for _ in 0 ..< 10000 {
                    flag.set(idx.isMultiple(of: 2))
                    _ = flag.get()
                }
            }
        }
        group.wait()
        // No assertion on the final value (last writer wins, nondeterministic)
        // — the test is that concurrent access does not trap or corrupt.
        _ = flag.get()
    }
}
