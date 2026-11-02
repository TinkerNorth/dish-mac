// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import Foundation
import GameController

/// The controllers as the feedback queue drives them: each slot's controller
/// as the main actor last filed it, and the rumble actuator made for it on
/// first use. Owned by the feedback queue: filings hop to it and the
/// actuators it hands out run on it, so nothing here waits on the main thread.
final class PadActuators {
    let queue: DispatchQueue
    private var controllers: [String: GCController] = [:]
    private var rumblers: [String: RumbleActuator] = [:]

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    /// Files the slot's controller, or none once it goes, on the queue.
    func file(_ controller: GCController?, for slotId: String) {
        queue.async { self.store(controller, for: slotId) }
    }

    /// The queue's half: a different controller under the slot drops the
    /// old one's engines.
    private func store(_ controller: GCController?, for slotId: String) {
        guard controllers[slotId] !== controller else { return }
        rumblers.removeValue(forKey: slotId)?.shutdown()
        controllers[slotId] = controller
    }

    var actuators: FeedbackActuators {
        FeedbackActuators(
            rumble: { [self] slotId, strong, weak, durationMs in
                rumbler(for: slotId)?.apply(strong: strong, weak: weak, durationMs: durationMs)
            },
            lightbar: { [self] slotId, red, green, blue in
                guard let light = controllers[slotId]?.light else { return }
                light.color = GCColor(red: Float(red) / 255.0, green: Float(green) / 255.0, blue: Float(blue) / 255.0)
            },
            triggerEffects: { [self] slotId, command in
                guard let dualSense = controllers[slotId]?.extendedGamepad as? GCDualSenseGamepad else { return }
                GameControllerInput.play(DualSenseTriggerEffect.decode(command.left), on: dualSense.leftTrigger)
                GameControllerInput.play(DualSenseTriggerEffect.decode(command.right), on: dualSense.rightTrigger)
            },
            playerLeds: { [self] slotId, player in
                controllers[slotId]?.playerIndex = GameControllerInput.playerIndex(for: player)
            }
        )
    }

    /// A pad without haptics takes no actuator and its rumble is dropped.
    private func rumbler(for slotId: String) -> RumbleActuator? {
        if let existing = rumblers[slotId] { return existing }
        guard let controller = controllers[slotId], let fresh = RumbleActuator(controller: controller) else { return nil }
        rumblers[slotId] = fresh
        return fresh
    }
}
