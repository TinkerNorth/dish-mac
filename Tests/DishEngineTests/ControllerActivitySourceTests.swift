// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import XCTest
@testable import DishEngine

@MainActor
final class ControllerActivitySourceTests: XCTestCase {

    private var lastInput: Int64 = 0
    private var now: Int64 = 0
    private var timeout: Int64 = 5 * 60 * 1000

    private func makeSource() -> ControllerActivitySource {
        ControllerActivitySource(
            lastInputMs: { [self] in lastInput },
            timeoutMs: { [self] in timeout },
            now: { [self] in now }
        )
    }

    func testTheInitialValueReadsTheWindowAtConstruction() {
        lastInput = 1000
        now = 1500
        XCTAssertTrue(makeSource().state)
        now = 1000 + timeout
        XCTAssertFalse(makeSource().state)
    }

    func testATickMovesTheStateOnlyWhenTheWindowFlips() {
        lastInput = 1000
        now = 1500
        let source = makeSource()
        var emissions: [Bool] = []
        let subscription = source.statePublisher.dropFirst().sink { emissions.append($0) }
        defer { subscription.cancel() }
        now = 2000
        source.tick()
        XCTAssertEqual(emissions, [], "still inside the window: no emission")
        now = 1000 + timeout
        source.tick()
        XCTAssertEqual(emissions, [false])
        lastInput = now
        source.tick()
        XCTAssertEqual(emissions, [false, true], "new input re-arms the window")
    }

    func testAShorterTimeoutExpiresSooner() {
        lastInput = 0
        now = 90000
        let source = makeSource()
        XCTAssertTrue(source.state)
        timeout = 60000
        source.tick()
        XCTAssertFalse(source.state)
    }

    func testTheUptimeClockIsMonotonicMilliseconds() {
        let first = uptimeMs()
        let second = uptimeMs()
        XCTAssertGreaterThanOrEqual(second, first)
        XCTAssertGreaterThan(first, 0)
    }
}
