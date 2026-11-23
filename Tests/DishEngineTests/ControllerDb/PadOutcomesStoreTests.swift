// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import XCTest
@testable import DishEngine

/// "Did it work?": a test asks once it has ended, the answer carries the
/// time it ended, oldest first, twenty a pad.
@MainActor
final class PadOutcomesStoreTests: XCTestCase {

    private var nowMs: Int64 = 100

    private func store() -> PadOutcomesStore {
        PadOutcomesStore { [weak self] in self?.nowMs ?? 0 }
    }

    func testATestAsksFromItsEndUntilItIsAnswered() {
        let outcomes = store()
        outcomes.started(.rumbleStrong, slotId: "pad")
        XCTAssertNil(outcomes.state.asking("pad"), "a running test asks nothing")
        nowMs = 500
        outcomes.ended(.rumbleStrong, slotId: "pad")
        XCTAssertEqual(outcomes.state.asking("pad"), EndedTest(test: .rumbleStrong, atMs: 500))
        nowMs = 9000
        outcomes.answer(slotId: "pad", worked: true)
        XCTAssertNil(outcomes.state.asking("pad"))
        XCTAssertEqual(
            outcomes.state.answers("pad"),
            [TestOutcome(test: .rumbleStrong, result: .worked, atMs: 500)],
            "the time the test ended"
        )
    }

    func testANewTestReplacesAnUnansweredQuestion() {
        let outcomes = store()
        outcomes.started(.rumbleWeak, slotId: "pad")
        outcomes.ended(.rumbleWeak, slotId: "pad")
        outcomes.started(.tone, slotId: "pad")
        outcomes.ended(.tone, slotId: "pad")
        outcomes.answer(slotId: "pad", worked: false)
        XCTAssertEqual(outcomes.state.answers("pad"), [TestOutcome(test: .tone, result: .didNotWork, atMs: 100)])
    }

    func testAnAnswerWithNoQuestionIsNothing() {
        let outcomes = store()
        outcomes.answer(slotId: "pad", worked: true)
        XCTAssertEqual(outcomes.state.answers("pad"), [])
        XCTAssertNil(outcomes.state.asking("pad"))
    }

    func testEachPadKeepsItsOwnAnswersInOrderAndOnlyTheNewestTwenty() {
        let outcomes = store()
        for at in 1 ... 22 {
            nowMs = Int64(at)
            outcomes.started(.stickDrift, slotId: "a")
            outcomes.ended(.stickDrift, slotId: "a")
            outcomes.answer(slotId: "a", worked: true)
        }
        outcomes.started(.microphone, slotId: "b")
        outcomes.ended(.microphone, slotId: "b")
        outcomes.answer(slotId: "b", worked: true)
        XCTAssertEqual(outcomes.state.answers("a").map(\.atMs), Array(3 ... 22).map(Int64.init))
        XCTAssertEqual(outcomes.state.answers("b").map(\.test), [.microphone])
    }

    func testEachStickTestNamesItsTest() {
        XCTAssertEqual(stickTest(.drift), .stickDrift)
        XCTAssertEqual(stickTest(.range), .stickRange)
    }
}
