// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import Foundation

/// What the feedback queue does with each pad's newest command: drive the
/// haptics, the light, the adaptive triggers and the player index. Called on
/// that queue only; the controller bridge in production, recorders in tests.
struct FeedbackActuators {
    var rumble: (_ slotId: String, _ strong: UInt16, _ weak: UInt16, _ durationMs: UInt16) -> Void
    var lightbar: (_ slotId: String, _ red: UInt8, _ green: UInt8, _ blue: UInt8) -> Void
    var triggerEffects: (_ slotId: String, _ command: TriggerEffectsCommand) -> Void
    var playerLeds: (_ slotId: String, _ player: Int) -> Void
}

/// The pads' feedback: one serial queue at the input queue's quality that
/// owns every actuator, and each slot's record of the commands waiting for it.
@MainActor
final class PadFeedback {
    nonisolated let queue: DispatchQueue
    private let actuators: FeedbackActuators
    /// One per slot, made on first use and kept, so a burst that spans a
    /// routing refresh still drains once.
    private var pads: [String: FeedbackPad] = [:]

    init(actuators: FeedbackActuators, queue: DispatchQueue = DispatchQueue(label: "dish.feedback", qos: .userInteractive)) {
        self.actuators = actuators
        self.queue = queue
    }

    func pad(for slotId: String) -> FeedbackPad {
        if let pad = pads[slotId] { return pad }
        let pad = FeedbackPad(slotId: slotId, queue: queue, actuators: actuators)
        pads[slotId] = pad
        return pad
    }
}

/// One pad's commands on their way to the feedback queue, the newest of each
/// kind: posted from any thread (a receive loop, the main actor), taken on
/// the queue. A post schedules a drain only when none is pending, so a burst
/// costs one hop and the queue applies its last value.
final class FeedbackPad {
    let slotId: String
    private let queue: DispatchQueue
    private let actuators: FeedbackActuators
    /// Each word holds the newest command packed with the pending bit, zero
    /// once the queue took it: written by the posters, taken by the queue.
    private let rumbleWord = AtomicWord.allocate()
    private let lightbarWord = AtomicWord.allocate()
    private let playerWord = AtomicWord.allocate()
    private let triggerMail = Mailbox<TriggerEffectsBox>()

    private static let pending: Int64 = 1 << 62

    init(slotId: String, queue: DispatchQueue, actuators: FeedbackActuators) {
        self.slotId = slotId
        self.queue = queue
        self.actuators = actuators
    }

    deinit {
        rumbleWord.deallocate()
        lightbarWord.deallocate()
        playerWord.deallocate()
    }

    func post(rumble command: RumbleCommand) {
        let packed = Int64(command.strongMagnitude) << 32 | Int64(command.weakMagnitude) << 16 | Int64(command.durationMs)
        guard rumbleWord.exchange(Self.pending | packed) & Self.pending == 0 else { return }
        queue.async { self.drainRumble() }
    }

    func post(lightbar command: LightbarCommand) {
        let packed = Int64(command.r) << 16 | Int64(command.g) << 8 | Int64(command.b)
        guard lightbarWord.exchange(Self.pending | packed) & Self.pending == 0 else { return }
        queue.async { self.drainLightbar() }
    }

    func post(player: Int) {
        let packed = Int64(UInt32(truncatingIfNeeded: player))
        guard playerWord.exchange(Self.pending | packed) & Self.pending == 0 else { return }
        queue.async { self.drainPlayer() }
    }

    func post(triggerEffects command: TriggerEffectsCommand) {
        guard triggerMail.post(TriggerEffectsBox(command)) else { return }
        queue.async { self.drainTriggerEffects() }
    }

    private func drainRumble() {
        let word = rumbleWord.exchange(0)
        guard word & Self.pending != 0 else { return }
        actuators.rumble(
            slotId,
            UInt16(truncatingIfNeeded: word >> 32),
            UInt16(truncatingIfNeeded: word >> 16),
            UInt16(truncatingIfNeeded: word)
        )
    }

    private func drainLightbar() {
        let word = lightbarWord.exchange(0)
        guard word & Self.pending != 0 else { return }
        actuators.lightbar(
            slotId,
            UInt8(truncatingIfNeeded: word >> 16),
            UInt8(truncatingIfNeeded: word >> 8),
            UInt8(truncatingIfNeeded: word)
        )
    }

    private func drainPlayer() {
        let word = playerWord.exchange(0)
        guard word & Self.pending != 0 else { return }
        actuators.playerLeds(slotId, Int(Int32(truncatingIfNeeded: word)))
    }

    private func drainTriggerEffects() {
        guard let box = triggerMail.take() else { return }
        actuators.triggerEffects(slotId, box.command)
    }
}

/// One trigger-effects command as the mailbox carries it.
final class TriggerEffectsBox {
    let command: TriggerEffectsCommand

    init(_ command: TriggerEffectsCommand) {
        self.command = command
    }
}
