// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishKernel
import DishKernelProbes
import XCTest

private final class CounterSource: StateSource<Int> {
    private(set) var startCount = 0
    private(set) var stopCount = 0

    func increment() {
        updateState { $0 + 1 }
    }

    func set(_ value: Int) {
        setState(value)
    }

    override func start() {
        startCount += 1
    }

    override func stop() {
        stopCount += 1
    }
}

final class StateSourceTests: XCTestCase {

    func testANewSubscriberReceivesTheCurrentStateFirst() {
        let source = CounterSource(initial: 7)
        let seen = probe(source)
        XCTAssertEqual(seen.values, [7])
    }

    func testSettingAnEqualStateDoesNotPublish() {
        let source = CounterSource(initial: 7)
        let seen = probe(source)
        source.set(7)
        XCTAssertEqual(seen.values, [7])
    }

    func testSettingADifferentStatePublishesOnce() {
        let source = CounterSource(initial: 7)
        let seen = probe(source)
        source.set(8)
        XCTAssertEqual(seen.values, [7, 8])
        XCTAssertEqual(source.state, 8)
    }

    func testUpdateStateAppliesTheReducerToTheCurrentState() {
        let source = CounterSource(initial: 1)
        let seen = probe(source)
        source.increment()
        source.increment()
        XCTAssertEqual(seen.values, [1, 2, 3])
    }

    func testAReducerReturningTheSameStateDoesNotPublish() {
        let source = CounterSource(initial: 5)
        let seen = probe(source)
        source.updateState { $0 }
        XCTAssertEqual(seen.values, [5])
    }

    func testLifecycleHooksAreOptInAndCalledOnce() {
        let source = CounterSource(initial: 0)
        source.start()
        source.stop()
        XCTAssertEqual(source.startCount, 1)
        XCTAssertEqual(source.stopCount, 1)
    }

    func testTheBaseLifecycleHooksDoNothing() {
        let source = StateSource<Int>(initial: 0)
        source.start()
        source.stop()
        XCTAssertEqual(source.state, 0)
    }
}
