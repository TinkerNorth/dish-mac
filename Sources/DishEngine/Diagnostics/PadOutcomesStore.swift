// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// "Did it work?" after each inspector test: per pad, the test running, the
// one that ended and waits for its answer, and the answers, the newest
// twenty, kept for the run. The Diagnostics bundle carries them; nothing is
// sent anywhere else.

import DishCore
import DishKernel
import Foundation

package struct PadOutcomes: Equatable {
    package var ledgers: [String: PadTestLedger] = [:]

    package init(ledgers: [String: PadTestLedger] = [:]) {
        self.ledgers = ledgers
    }

    /// The test that ended on the pad and has not been answered for.
    package func asking(_ slotId: String) -> EndedTest? {
        ledgers[slotId]?.asking
    }

    /// The pad's answers, oldest first.
    package func answers(_ slotId: String) -> [TestOutcome] {
        ledgers[slotId]?.answers ?? []
    }
}

@MainActor
package final class PadOutcomesStore: StateSource<PadOutcomes> {
    private let now: () -> Int64

    init(now: @escaping () -> Int64 = { wallClockMs() }) {
        self.now = now
        super.init(initial: PadOutcomes())
    }

    /// A test started on the pad: its question waits for its end, and any
    /// question still unanswered goes.
    func started(_ test: InspectorTest, slotId: String) {
        updateLedger(slotId) { $0.started(test) }
    }

    /// The test ended now: the page asks, and the answer carries this time.
    func ended(_ test: InspectorTest, slotId: String) {
        let atMs = now()
        updateLedger(slotId) { $0.ended(test, atMs: atMs) }
    }

    /// The person's answer to the question waiting on the pad; nothing when
    /// none waits.
    func answer(slotId: String, worked: Bool) {
        updateLedger(slotId) { $0.answered(worked: worked) }
    }

    private func updateLedger(_ slotId: String, _ change: (inout PadTestLedger) -> Void) {
        var ledger = state.ledgers[slotId] ?? PadTestLedger()
        change(&ledger)
        updateState { var next = $0
            next.ledgers[slotId] = ledger
            return next
        }
    }
}

func stickTest(_ kind: StickTestKind) -> InspectorTest {
    switch kind {
    case .drift: .stickDrift
    case .range: .stickRange
    }
}
