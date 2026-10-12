// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Combine
import DishKernel
import DishKernelProbes
import XCTest

private func sum(_ first: Int, _ second: Int) -> Int {
    first + second
}

private func larger(_ first: Int, _ second: Int) -> Int {
    max(first, second)
}

private func doubled(_ first: Int) -> Int {
    first * 2
}

private func sumOfThree(_ first: Int, _ second: Int, _ third: Int) -> Int {
    first + second + third
}

private func sumOfFour(_ first: Int, _ second: Int, _ third: Int, _ fourth: Int) -> Int {
    first + second + third + fourth
}

final class ComposerTests: XCTestCase {

    func testDerivesEagerlyFromTheUpstreamsCurrentValues() {
        let first = StateSource<Int>(initial: 1)
        let second = StateSource<Int>(initial: 2)
        let composer = Composer(first.statePublisher, second.statePublisher, initial: 0, transform: sum)
        XCTAssertEqual(composer.state, 3)
    }

    func testTheProbeSeesTheDerivedValueNotTheInitialPlaceholder() {
        let first = StateSource<Int>(initial: 1)
        let second = StateSource<Int>(initial: 2)
        let composer = Composer(first.statePublisher, second.statePublisher, initial: 0, transform: sum)
        let seen = probe(composer)
        XCTAssertEqual(seen.values, [3])
    }

    func testRecomputesWhenAnyUpstreamChanges() {
        let first = StateSource<Int>(initial: 1)
        let second = StateSource<Int>(initial: 2)
        let composer = Composer(first.statePublisher, second.statePublisher, initial: 0, transform: sum)
        let seen = probe(composer)
        first.setState(10)
        second.setState(5)
        XCTAssertEqual(seen.values, [3, 12, 15])
    }

    func testAnUpstreamChangeThatLeavesTheResultEqualDoesNotPublish() {
        let first = StateSource<Int>(initial: 1)
        let second = StateSource<Int>(initial: 5)
        let composer = Composer(first.statePublisher, second.statePublisher, initial: 0, transform: larger)
        let seen = probe(composer)
        first.setState(3)
        XCTAssertEqual(seen.values, [5])
    }

    func testOneUpstreamComposer() {
        let first = StateSource<Int>(initial: 4)
        let composer = Composer(first.statePublisher, initial: 0, transform: doubled)
        first.setState(6)
        XCTAssertEqual(composer.state, 12)
    }

    func testThreeUpstreamComposer() {
        let first = StateSource<Int>(initial: 1)
        let second = StateSource<Int>(initial: 2)
        let third = StateSource<Int>(initial: 3)
        let composer = Composer(first.statePublisher, second.statePublisher, third.statePublisher, initial: 0, transform: sumOfThree)
        third.setState(30)
        XCTAssertEqual(composer.state, 33)
    }

    func testFourUpstreamComposer() {
        let first = StateSource<Int>(initial: 1)
        let second = StateSource<Int>(initial: 2)
        let third = StateSource<Int>(initial: 3)
        let fourth = StateSource<Int>(initial: 4)
        let composer = Composer(
            first.statePublisher,
            second.statePublisher,
            third.statePublisher,
            fourth.statePublisher,
            initial: 0,
            transform: sumOfFour
        )
        fourth.setState(40)
        XCTAssertEqual(composer.state, 46)
    }

    func testAComposerCanFeedAnotherComposer() {
        let first = StateSource<Int>(initial: 1)
        let second = StateSource<Int>(initial: 2)
        let total = Composer(first.statePublisher, second.statePublisher, initial: 0, transform: sum)
        let twice = Composer(total.statePublisher, initial: 0, transform: doubled)
        first.setState(5)
        XCTAssertEqual(twice.state, 14)
    }
}
