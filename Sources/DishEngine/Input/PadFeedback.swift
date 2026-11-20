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

    private let clockMs: @Sendable () -> Int64

    init(
        actuators: FeedbackActuators,
        queue: DispatchQueue = DispatchQueue(label: "dish.feedback", qos: .userInteractive),
        clockMs: @escaping @Sendable () -> Int64 = wallClockMs
    ) {
        self.actuators = actuators
        self.queue = queue
        self.clockMs = clockMs
    }

    func pad(for slotId: String) -> FeedbackPad {
        if let pad = pads[slotId] { return pad }
        let pad = FeedbackPad(slotId: slotId, queue: queue, actuators: actuators, tally: FeedbackTally(clockMs: clockMs))
        pads[slotId] = pad
        return pad
    }

    /// What reached the slot so far; nothing for a slot no command reached.
    func outputCounts(slotId: String) -> PadOutputCounts {
        pads[slotId]?.tally.counts() ?? PadOutputCounts()
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
    let tally: FeedbackTally

    private static let pending: Int64 = 1 << 62

    init(slotId: String, queue: DispatchQueue, actuators: FeedbackActuators, tally: FeedbackTally) {
        self.slotId = slotId
        self.queue = queue
        self.actuators = actuators
        self.tally = tally
    }

    deinit {
        rumbleWord.deallocate()
        lightbarWord.deallocate()
        playerWord.deallocate()
    }

    func post(rumble command: RumbleCommand) {
        let packed = Int64(command.strongMagnitude) << 32 | Int64(command.weakMagnitude) << 16 | Int64(command.durationMs)
        tally.record(.rumble, packed: packed)
        guard rumbleWord.exchange(Self.pending | packed) & Self.pending == 0 else { return }
        queue.async { self.drainRumble() }
    }

    func post(lightbar command: LightbarCommand) {
        let packed = Int64(command.r) << 16 | Int64(command.g) << 8 | Int64(command.b)
        tally.record(.lightbar, packed: packed)
        guard lightbarWord.exchange(Self.pending | packed) & Self.pending == 0 else { return }
        queue.async { self.drainLightbar() }
    }

    func post(player: Int) {
        let packed = Int64(UInt32(truncatingIfNeeded: player))
        tally.record(.playerLeds, packed: packed)
        guard playerWord.exchange(Self.pending | packed) & Self.pending == 0 else { return }
        queue.async { self.drainPlayer() }
    }

    func post(triggerEffects command: TriggerEffectsCommand) {
        tally.record(.triggerEffects, packed: 0)
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

/// Every command posted to one pad, by lane: how many, the newest packed as
/// the pad's own word packs it, and when. Each post adds one relaxed
/// increment and two relaxed stores; the main actor reads them only when a
/// report is made, so a count and its last value may be one post apart.
final class FeedbackTally: @unchecked Sendable {
    enum Lane: Int, CaseIterable {
        case rumble
        case lightbar
        case playerLeds
        case triggerEffects
    }

    private enum Field: Int, CaseIterable {
        case count
        case last
        case atMs
    }

    private static let wordCount = Lane.allCases.count * Field.allCases.count

    private let words = UnsafeMutablePointer<Int64>.allocate(capacity: wordCount)
    private let clockMs: @Sendable () -> Int64

    init(clockMs: @escaping @Sendable () -> Int64) {
        self.clockMs = clockMs
        words.initialize(repeating: 0, count: Self.wordCount)
    }

    deinit {
        words.deallocate()
    }

    private func word(_ lane: Lane, _ field: Field) -> AtomicWord {
        AtomicWord(address: words + lane.rawValue * Field.allCases.count + field.rawValue)
    }

    func record(_ lane: Lane, packed: Int64) {
        word(lane, .last).storeRelaxed(packed)
        word(lane, .atMs).storeRelaxed(clockMs())
        word(lane, .count).fetchAddRelaxed(1)
    }

    private func count(_ lane: Lane) -> Int {
        Int(word(lane, .count).loadRelaxed())
    }

    /// The newest packed value and its stamp, nil before the lane's first post.
    private func last(_ lane: Lane) -> (packed: Int64, atMs: Int64)? {
        guard count(lane) > 0 else { return nil }
        return (word(lane, .last).loadRelaxed(), word(lane, .atMs).loadRelaxed())
    }

    func counts() -> PadOutputCounts {
        let rumble = last(.rumble).map { word in
            RumbleFacts(
                strong: UInt16(truncatingIfNeeded: word.packed >> 32),
                weak: UInt16(truncatingIfNeeded: word.packed >> 16),
                durationMs: UInt16(truncatingIfNeeded: word.packed),
                atMs: word.atMs
            )
        }
        let lightbar = last(.lightbar).map { word in
            LightbarFacts(
                r: UInt8(truncatingIfNeeded: word.packed >> 16),
                g: UInt8(truncatingIfNeeded: word.packed >> 8),
                b: UInt8(truncatingIfNeeded: word.packed),
                atMs: word.atMs
            )
        }
        return PadOutputCounts(
            rumble: count(.rumble),
            lastRumble: rumble,
            lightbar: count(.lightbar),
            lastLightbar: lightbar,
            playerLeds: count(.playerLeds),
            lastPlayer: last(.playerLeds).map { Int(Int32(truncatingIfNeeded: $0.packed)) },
            triggerEffects: count(.triggerEffects)
        )
    }
}
