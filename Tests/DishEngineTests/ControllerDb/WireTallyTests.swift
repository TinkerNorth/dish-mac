// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import XCTest
@testable import DishEngine

/// The hot path's counters for the bundle: one relaxed increment per
/// message, read only when a report is made.
final class WireTallyTests: XCTestCase {

    func testEachSentMessageCountsUnderItsKind() {
        let tally = WireTally()
        tally.sent(ProtocolConstants.msgInput)
        tally.sent(ProtocolConstants.msgInput)
        tally.sent(ProtocolConstants.msgTouchpad)
        let counts = tally.counts()
        XCTAssertEqual(counts.sent[.input], 2)
        XCTAssertEqual(counts.sent[.pointer], 1)
        XCTAssertEqual(counts.sent[.mic], 0)
    }

    func testEachReceivedMessageCountsUnderItsKind() {
        let tally = WireTally()
        tally.received(ProtocolConstants.msgRumble)
        tally.received(ProtocolConstants.msgSessionClose)
        let counts = tally.counts()
        XCTAssertEqual(counts.received[.rumble], 1)
        XCTAssertEqual(counts.received[.sessionClose], 1)
        XCTAssertEqual(counts.sent.values.reduce(0, +), 0, "a received message is not a sent one")
    }

    func testATypeOfNoKindCountsNowhere() {
        let tally = WireTally()
        tally.sent(ProtocolConstants.msgRumble)
        tally.received(ProtocolConstants.msgInput)
        tally.received(0xFFFF)
        let counts = tally.counts()
        XCTAssertEqual(counts.sent.values.reduce(0, +), 0)
        XCTAssertEqual(counts.received.values.reduce(0, +), 0)
    }

    func testCountsFromManyThreadsAreAllKept() {
        let tally = WireTally()
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            for _ in 0 ..< 1000 {
                tally.sent(ProtocolConstants.msgInput)
            }
        }
        XCTAssertEqual(tally.counts().sent[.input], 8000)
    }
}

/// Every feedback command that reaches a pad, counted where it lands, its
/// newest value and when.
@MainActor
final class FeedbackTallyTests: XCTestCase {

    private func feedback() -> PadFeedback {
        let ignore = FeedbackActuators(
            rumble: { _, _, _, _ in },
            lightbar: { _, _, _, _ in },
            triggerEffects: { _, _ in },
            playerLeds: { _, _ in }
        )
        return PadFeedback(actuators: ignore, clockMs: { 77 })
    }

    func testASlotNoCommandReachedHasNothing() {
        XCTAssertEqual(feedback().outputCounts(slotId: "pad"), PadOutputCounts())
    }

    func testEachLaneCountsItsCommandsAndKeepsTheNewest() {
        let feedback = feedback()
        let pad = feedback.pad(for: "pad")
        pad.post(rumble: RumbleCommand(controllerIndex: 0, strongMagnitude: 100, weakMagnitude: 5, durationMs: 50))
        pad.post(rumble: RumbleCommand(controllerIndex: 0, strongMagnitude: 32768, weakMagnitude: 0, durationMs: 100))
        pad.post(lightbar: LightbarCommand(controllerIndex: 0, r: 0, g: 0, b: 255))
        pad.post(player: 2)
        let counts = feedback.outputCounts(slotId: "pad")
        XCTAssertEqual(counts.rumble, 2)
        XCTAssertEqual(counts.lastRumble, RumbleFacts(strong: 32768, weak: 0, durationMs: 100, atMs: 77))
        XCTAssertEqual(counts.lightbar, 1)
        XCTAssertEqual(counts.lastLightbar, LightbarFacts(r: 0, g: 0, b: 255, atMs: 77))
        XCTAssertEqual(counts.playerLeds, 1)
        XCTAssertEqual(counts.lastPlayer, 2)
        XCTAssertEqual(counts.triggerEffects, 0)
    }

    func testACoalescedCommandStillCounts() {
        let feedback = feedback()
        let pad = feedback.pad(for: "pad")
        for strength in 1 ... 5 {
            pad.post(rumble: RumbleCommand(controllerIndex: 0, strongMagnitude: UInt16(strength), weakMagnitude: 0, durationMs: 10))
        }
        XCTAssertEqual(feedback.outputCounts(slotId: "pad").rumble, 5)
    }

    func testTriggerEffectsAreCounted() throws {
        let feedback = feedback()
        let payload = Data([0] + [UInt8](repeating: 0, count: 22))
        let command = try XCTUnwrap(TriggerEffectsCommand.parse(payload))
        feedback.pad(for: "pad").post(triggerEffects: command)
        XCTAssertEqual(feedback.outputCounts(slotId: "pad").triggerEffects, 1)
        XCTAssertNil(feedback.outputCounts(slotId: "pad").lastRumble)
    }
}
