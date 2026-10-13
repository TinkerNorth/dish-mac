// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import Foundation

/// The Diagnostics inspector's intents: arming it on a controller, the stick
/// tests, the rumble bench and the two audio tests.
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

    /// Straight to the pad, whatever its rumble switch says: the bench proves
    /// the motors, and the actuator stops the buzz when its time runs out.
    func testRumble(slotId: String, motor: BuzzMotor) {
        let buzz = testBuzz(for: motor)
        input.applyRumble(deviceId: slotId, strongMagnitude: buzz.strong, weakMagnitude: buzz.weak, durationMs: buzz.durationMs)
    }

    /// False when the pad has no speaker route.
    @discardableResult
    func playTestTone(slotId: String) -> Bool {
        audio.engine.playTone(for: slotId)
    }

    /// False when the pad has no microphone route or the system withholds it.
    @discardableResult
    func startMicMeter(slotId: String) -> Bool {
        audio.engine.startMicMeter(for: slotId)
    }

    func stopMicMeter(slotId: String) {
        audio.engine.stopMicMeter(for: slotId)
    }
}
