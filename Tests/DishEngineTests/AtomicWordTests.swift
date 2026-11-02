// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Foundation
import XCTest
@testable import DishEngine

/// The word the hot paths' atomics stand on: each operation returns what
/// its contract says, and several threads racing on one word lose nothing.
final class AtomicWordTests: XCTestCase {

    func testAWordHoldsItsInitialValue() {
        let word = AtomicWord.allocate(-7)
        defer { word.deallocate() }
        XCTAssertEqual(word.load(), -7)
        XCTAssertEqual(word.loadRelaxed(), -7)
    }

    func testStoresAreWhatTheNextLoadReads() {
        let word = AtomicWord.allocate()
        defer { word.deallocate() }
        word.store(41)
        XCTAssertEqual(word.load(), 41)
        word.storeRelaxed(42)
        XCTAssertEqual(word.load(), 42)
    }

    func testFetchAddAndExchangeReturnTheValueBefore() {
        let word = AtomicWord.allocate(10)
        defer { word.deallocate() }
        XCTAssertEqual(word.fetchAdd(5), 10)
        XCTAssertEqual(word.fetchAddRelaxed(-3), 15)
        XCTAssertEqual(word.exchange(100), 12)
        XCTAssertEqual(word.load(), 100)
    }

    func testCompareExchangeStoresOnlyOverTheExpectedValue() {
        let word = AtomicWord.allocate(3)
        defer { word.deallocate() }
        XCTAssertFalse(word.compareExchange(expected: 4, desired: 9))
        XCTAssertEqual(word.load(), 3, "a lost exchange leaves the word alone")
        XCTAssertTrue(word.compareExchange(expected: 3, desired: 9))
        XCTAssertEqual(word.load(), 9)
    }

    func testRacingAddsAndCompareExchangeLoopsLoseNothing() {
        let word = AtomicWord.allocate()
        defer { word.deallocate() }
        hammer { thread in
            if thread % 2 == 0 {
                word.fetchAdd(1)
            } else {
                var seen = word.loadRelaxed()
                while !word.compareExchange(expected: seen, desired: seen + 1) {
                    seen = word.loadRelaxed()
                }
            }
        }
        XCTAssertEqual(word.load(), Int64(Self.threads * Self.rounds))
    }

    private static let threads = 4
    private static let rounds = 20000

    private func hammer(_ step: @escaping (Int) -> Void) {
        let group = DispatchGroup()
        for thread in 0 ..< Self.threads {
            group.enter()
            Thread {
                for _ in 0 ..< Self.rounds {
                    step(thread)
                }
                group.leave()
            }.start()
        }
        XCTAssertEqual(group.wait(timeout: .now() + 20), .success)
    }
}
