// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// "Did it work?" after each inspector test: the test waiting for its answer
// per pad, and the answers, the newest twenty per pad, kept for the run.
// The Diagnostics bundle carries them; nothing is sent anywhere else.

import DishCore
import DishKernel
import Foundation

package struct PadOutcomes: Equatable {
    /// The test each pad ran last and has not been answered for.
    package var asking: [String: InspectorTest] = [:]
    /// Each pad's answers, oldest first.
    package var answers: [String: [TestOutcome]] = [:]

    package init(asking: [String: InspectorTest] = [:], answers: [String: [TestOutcome]] = [:]) {
        self.asking = asking
        self.answers = answers
    }
}

@MainActor
package final class PadOutcomesStore: StateSource<PadOutcomes> {
    private let now: () -> Int64

    init(now: @escaping () -> Int64 = { wallClockMs() }) {
        self.now = now
        super.init(initial: PadOutcomes())
    }

    /// A test ran on the pad: its question replaces any unanswered one.
    func ran(_ test: InspectorTest, slotId: String) {
        updateState { var next = $0
            next.asking[slotId] = test
            return next
        }
    }

    /// The person's answer to the question waiting on the pad; nothing when
    /// none waits.
    func answer(slotId: String, worked: Bool) {
        guard let test = state.asking[slotId] else { return }
        let outcome = TestOutcome(test: test, result: worked ? .worked : .didNotWork, atMs: now())
        updateState { var next = $0
            next.asking.removeValue(forKey: slotId)
            next.answers[slotId] = appendingOutcome(next.answers[slotId] ?? [], outcome)
            return next
        }
    }
}

/// The bench's motor as the test the bundle names.
func rumbleTest(_ motor: BuzzMotor) -> InspectorTest {
    switch motor {
    case .weak: .rumbleWeak
    case .strong: .rumbleStrong
    case .both: .rumbleBoth
    }
}

func stickTest(_ kind: StickTestKind) -> InspectorTest {
    switch kind {
    case .drift: .stickDrift
    case .range: .stickRange
    }
}
