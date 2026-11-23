// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import Foundation

/// The Diagnostics inspector's intents: arming it on a controller, the stick
/// tests, the feedback bench and the audio tests. Each test tells the
/// outcomes when it starts and when it ends, so the page asks once it is
/// over.
package extension AppModel {

    func inspect(slotId: String) {
        inspector.arm(slotId)
    }

    func stopInspecting() {
        inspector.disarm()
    }

    func startStickTest(_ kind: StickTestKind) {
        inspector.startStickTest(kind)
    }

    /// Straight to the pad, whatever its switches say: the bench proves the
    /// pad, and a state surface the test holds goes back to what the game
    /// set when it ends.
    func runFeedbackTest(_ test: FeedbackTest, slotId: String) {
        bench.run(test, slotId: slotId)
    }

    /// The tone on the pad's speaker pair; nothing when the pad has no
    /// speaker route or a tone already plays.
    func playTestTone(slotId: String) {
        playTone(slotId: slotId, on: .speaker, test: .tone)
    }

    /// The same tone on the pad's haptics lanes.
    func playHapticsTone(slotId: String) {
        playTone(slotId: slotId, on: .haptics, test: .haptics)
    }

    /// Nothing when the pad has no microphone route or the system withholds it.
    func startMicMeter(slotId: String) {
        let listening = audio.engine.startMicMeter(for: slotId) { [weak self] in self?.outcomes.ended(.microphone, slotId: slotId) }
        guard listening else { return }
        outcomes.started(.microphone, slotId: slotId)
    }

    func stopMicMeter(slotId: String) {
        audio.engine.stopMicMeter(for: slotId)
    }
}

private extension AppModel {
    func playTone(slotId: String, on lane: ToneLane, test: InspectorTest) {
        let playing = audio.engine.playTone(for: slotId, on: lane) { [weak self] in self?.outcomes.ended(test, slotId: slotId) }
        guard playing else { return }
        outcomes.started(test, slotId: slotId)
    }
}
