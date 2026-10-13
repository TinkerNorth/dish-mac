// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import XCTest
@testable import DishCore

/// The two-frame reorder window: in-order play, a late frame still in its
/// slot, a lost frame concealed once, a frame after its slot dropped, a
/// suppressed window silence, and the sequence wrapping.
final class AudioPlayoutTests: XCTestCase {

    private func frame(_ seq: UInt16) -> AudioFrame {
        AudioFrame(controllerIndex: 0, seq: seq, opus: Data([UInt8(seq & 0xFF)]))
    }

    private func opus(_ seq: UInt16) -> PlayoutDecision {
        .frame(Data([UInt8(seq & 0xFF)]))
    }

    func testTheLaneIsSilentUntilTheWindowFills() {
        var lane = AudioPlayout()
        XCTAssertEqual(lane.pull(), .silence)
        lane.push(frame(10))
        XCTAssertEqual(lane.pull(), .silence, "one frame is not a window")
        lane.push(frame(11))
        XCTAssertEqual(lane.pull(), opus(10))
        XCTAssertEqual(lane.pull(), opus(11))
        XCTAssertEqual(lane.played, 2)
    }

    func testAFrameOneSlotLateStillPlaysInOrder() {
        var lane = AudioPlayout()
        lane.push(frame(1))
        lane.push(frame(3))
        XCTAssertEqual(lane.pull(), opus(1))
        lane.push(frame(2))
        XCTAssertEqual(lane.pull(), opus(2))
        XCTAssertEqual(lane.pull(), opus(3))
        XCTAssertEqual(lane.concealed, 0)
        XCTAssertEqual(lane.lateDrops, 0)
    }

    func testALostFrameIsConcealedOnceAndTheLateCopyDropped() {
        var lane = AudioPlayout()
        lane.push(frame(1))
        lane.push(frame(3))
        XCTAssertEqual(lane.pull(), opus(1))
        XCTAssertEqual(lane.pull(), .conceal, "2 never came and 3 is already here")
        lane.push(frame(2))
        XCTAssertEqual(lane.lateDrops, 1, "after its slot a frame is noise")
        XCTAssertEqual(lane.pull(), opus(3))
        XCTAssertEqual(lane.concealed, 1)
    }

    func testASuppressedWindowIsSilenceNotAHole() {
        var lane = AudioPlayout()
        lane.push(frame(1))
        lane.push(frame(2))
        XCTAssertEqual(lane.pull(), opus(1))
        XCTAssertEqual(lane.pull(), opus(2))
        XCTAssertEqual(lane.pull(), .silence, "the server sent nothing and advanced nothing")
        XCTAssertEqual(lane.pull(), .silence)
        lane.push(frame(3))
        XCTAssertEqual(lane.pull(), opus(3), "the next frame plays without a conceal")
        XCTAssertEqual(lane.concealed, 0)
    }

    func testTheSequenceWraps() {
        var lane = AudioPlayout()
        lane.push(frame(0xFFFF))
        lane.push(frame(0x0000))
        XCTAssertEqual(lane.pull(), opus(0xFFFF))
        XCTAssertEqual(lane.pull(), opus(0x0000))
        lane.push(frame(0xFFFE))
        XCTAssertEqual(lane.lateDrops, 1, "behind the playhead across the wrap")
        XCTAssertEqual(AudioPlayout.distance(from: 0xFFFF, to: 0x0001), 2)
        XCTAssertEqual(AudioPlayout.distance(from: 0x0001, to: 0xFFFF), -2)
    }

    func testResetStartsTheLaneFresh() {
        var lane = AudioPlayout()
        lane.push(frame(5))
        lane.push(frame(6))
        _ = lane.pull()
        lane.reset()
        XCTAssertEqual(lane, AudioPlayout())
        XCTAssertEqual(lane.pull(), .silence)
    }
}
