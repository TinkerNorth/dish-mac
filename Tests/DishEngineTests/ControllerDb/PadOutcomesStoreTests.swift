// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import XCTest
@testable import DishEngine

/// "Did it work?": a test asks, the answer is kept, oldest first, twenty a pad.
@MainActor
final class PadOutcomesStoreTests: XCTestCase {

    private var nowMs: Int64 = 100

    private func store() -> PadOutcomesStore {
        PadOutcomesStore { [weak self] in self?.nowMs ?? 0 }
    }

    func testATestThatRanAsksUntilItIsAnswered() {
        let outcomes = store()
        outcomes.ran(.rumbleStrong, slotId: "pad")
        XCTAssertEqual(outcomes.state.asking["pad"], .rumbleStrong)
        outcomes.answer(slotId: "pad", worked: true)
        XCTAssertNil(outcomes.state.asking["pad"])
        XCTAssertEqual(outcomes.state.answers["pad"], [TestOutcome(test: .rumbleStrong, result: .worked, atMs: 100)])
    }

    func testANewTestReplacesAnUnansweredQuestion() {
        let outcomes = store()
        outcomes.ran(.rumbleWeak, slotId: "pad")
        outcomes.ran(.tone, slotId: "pad")
        outcomes.answer(slotId: "pad", worked: false)
        XCTAssertEqual(outcomes.state.answers["pad"], [TestOutcome(test: .tone, result: .didNotWork, atMs: 100)])
    }

    func testAnAnswerWithNoQuestionIsNothing() {
        let outcomes = store()
        outcomes.answer(slotId: "pad", worked: true)
        XCTAssertEqual(outcomes.state, PadOutcomes())
    }

    func testEachPadKeepsItsOwnAnswersInOrderAndOnlyTheNewestTwenty() {
        let outcomes = store()
        for at in 1 ... 22 {
            nowMs = Int64(at)
            outcomes.ran(.stickDrift, slotId: "a")
            outcomes.answer(slotId: "a", worked: true)
        }
        outcomes.ran(.microphone, slotId: "b")
        outcomes.answer(slotId: "b", worked: true)
        XCTAssertEqual(outcomes.state.answers["a"]?.map(\.atMs), Array(3 ... 22).map(Int64.init))
        XCTAssertEqual(outcomes.state.answers["b"]?.map(\.test), [.microphone])
    }

    func testEachBenchNamesItsTest() {
        XCTAssertEqual(BuzzMotor.allCases.map(rumbleTest), [.rumbleWeak, .rumbleStrong, .rumbleBoth])
        XCTAssertEqual(stickTest(.drift), .stickDrift)
        XCTAssertEqual(stickTest(.range), .stickRange)
    }
}
