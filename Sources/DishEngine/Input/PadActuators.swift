// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import Foundation
import GameController

/// The controllers as the feedback queue drives them: each slot's controller
/// as the main actor last filed it, the rumble actuator made for it on first
/// use, and a Direct pad's own output where it drives its own rumble. Owned
/// by the feedback queue: filings hop to it and the actuators it hands out
/// run on it, so nothing here waits on the main thread.
final class PadActuators {
    let queue: DispatchQueue
    private var controllers: [String: GCController] = [:]
    private var rumblers: [String: RumbleActuator] = [:]
    private var outputs: [String: DirectOutput] = [:]

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    /// Files the slot's controller, or none once it goes, on the queue.
    func file(_ controller: GCController?, for slotId: String) {
        queue.async { self.store(controller, for: slotId) }
    }

    /// Files the output that takes the slot's rumble, or none, on the queue.
    func fileOutput(_ output: DirectOutput?, for slotId: String) {
        queue.async { self.outputs[slotId] = output }
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
                rumble(slotId, strong: strong, weak: weak, durationMs: durationMs)
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

    /// A pad that drives its own rumble report takes it; any other rides its
    /// controller's engines.
    private func rumble(_ slotId: String, strong: UInt16, weak: UInt16, durationMs: UInt16) {
        if let output = outputs[slotId] { return output.rumble(strong: strong, weak: weak, durationMs: durationMs) }
        rumbler(for: slotId)?.apply(strong: strong, weak: weak, durationMs: durationMs)
    }

    /// A pad without haptics takes no actuator and its rumble is dropped.
    private func rumbler(for slotId: String) -> RumbleActuator? {
        if let existing = rumblers[slotId] { return existing }
        guard let controller = controllers[slotId], let fresh = RumbleActuator(controller: controller) else { return nil }
        rumblers[slotId] = fresh
        return fresh
    }
}
