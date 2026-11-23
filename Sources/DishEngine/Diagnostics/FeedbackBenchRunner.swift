// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// The inspector's feedback tests, driven from this Mac alone (the contract's
// "The bench"): each test's program from the core, its writes posted to the
// pad's feedback record at their times, the state surface it holds taken from
// the game for the test's length and given back at its end, and the start and
// the end told to the outcomes, so the page asks once the test is over. A pad
// runs one feedback test at a time; the state is the test each pad runs.

import DishCore
import DishKernel
import Foundation

@MainActor
final class FeedbackBenchRunner: StateSource<[String: FeedbackTest]> {
    private let feedback: PadFeedback
    private let outcomes: PadOutcomesStore
    private let scheduler: InputPathScheduler

    init(feedback: PadFeedback, outcomes: PadOutcomesStore, scheduler: InputPathScheduler = LiveInputPathScheduler()) {
        self.feedback = feedback
        self.outcomes = outcomes
        self.scheduler = scheduler
        super.init(initial: [:])
    }

    /// Nothing while another feedback test runs on the pad.
    func run(_ test: FeedbackTest, slotId: String) {
        guard state[slotId] == nil else { return }
        let program = benchProgram(test)
        let pad = feedback.pad(for: slotId)
        if let surface = program.surface { pad.benchTake(surface) }
        for step in program.steps {
            scheduler.after(ms: Int(step.atMs)) { pad.bench(step.action) }
        }
        scheduler.after(ms: Int(program.durationMs)) { [weak self] in self?.finish(test, program: program, slotId: slotId) }
        updateState { var next = $0
            next[slotId] = test
            return next
        }
        outcomes.started(test.inspectorTest, slotId: slotId)
    }

    private func finish(_ test: FeedbackTest, program: BenchProgram, slotId: String) {
        if let surface = program.surface { feedback.pad(for: slotId).benchRelease(surface) }
        updateState { var next = $0
            next.removeValue(forKey: slotId)
            return next
        }
        outcomes.ended(test.inspectorTest, slotId: slotId)
    }
}

package extension ControllerCapabilities {
    /// What the bench reads of the path: the same facts the game's writes
    /// and the descriptor's claims are made from.
    var benchCarriage: BenchCarriage {
        BenchCarriage(
            rumble: hasRumble,
            triggerRumble: hasTriggerRumble,
            lightbar: hasLightbar,
            playerLeds: hasPlayerLeds,
            triggerEffects: hasTriggerEffects,
            speaker: hasSpeaker,
            hapticLanes: hasHapticLanes,
            mic: hasMic
        )
    }
}
