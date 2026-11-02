// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import XCTest

/// A frame carries a 16-bit sequence; the bench maps each arrival back to
/// the frame's send stamp, across the sequence's wrap, and reads the stream's
/// latency, losses, repeats and longest silence from the matches.
final class SequenceStampsTests: XCTestCase {

    func testASequenceUnwrapsToTheNearestFrameWithItsLowBits() {
        XCTAssertEqual(unwrapSequence(5, near: 3), 5)
        XCTAssertEqual(unwrapSequence(0, near: 65535), 65536, "the sequence wrapped forward")
        XCTAssertEqual(unwrapSequence(65535, near: 65536), 65535, "a frame one behind the wrap")
        XCTAssertEqual(unwrapSequence(2, near: 70000), 65538)
        XCTAssertEqual(unwrapSequence(65535, near: 0), -1, "before the first frame resolves to no frame")
    }

    func testEachArrivalIsMatchedToItsFramesStamp() {
        let summary = StreamLatency(
            sentNs: [0, 1000, 2000, 3000],
            arrivals: [arrival(0, 500), arrival(1, 1600), arrival(3, 3100), arrival(1, 3200)]
        )
        XCTAssertEqual(summary.frames, 4)
        XCTAssertEqual(summary.received, 3)
        XCTAssertEqual(summary.duplicates, 1, "frame 1 arrived twice and counts once")
        XCTAssertEqual(summary.drops, 1, "frame 2 never arrived")
        XCTAssertEqual(summary.p50Ns, 500)
        XCTAssertEqual(summary.maxNs, 600)
        XCTAssertEqual(summary.longestGapNs, 1500)
        XCTAssertEqual(summary.overLimit, 0)
    }

    func testAStreamLongerThanTheSequenceStillResolvesEveryFrame() {
        let frames = 70000
        let sent = (0 ..< frames).map { UInt64($0) * 1000 }
        let arrivals = (0 ..< frames).map { arrival(UInt16(truncatingIfNeeded: $0), UInt64($0) * 1000 + 10) }
        let summary = StreamLatency(sentNs: sent, arrivals: arrivals)
        XCTAssertEqual(summary.received, frames)
        XCTAssertEqual(summary.drops, 0)
        XCTAssertEqual(summary.maxNs, 10)
        XCTAssertEqual(summary.duplicates, 0)
    }

    func testAFrameSlowerThanAMillisecondIsCountedOverTheLimit() {
        let summary = StreamLatency(sentNs: [0, 0, 0], arrivals: [arrival(0, 10), arrival(1, 2_000_000), arrival(2, 2_000_001)])
        XCTAssertEqual(summary.overLimit, 2)
        XCTAssertEqual(summary.maxNs, 2_000_001)
    }

    func testNoArrivalsReadAsEveryFrameDropped() {
        let summary = StreamLatency(sentNs: [0, 1000], arrivals: [])
        XCTAssertEqual(summary.received, 0)
        XCTAssertEqual(summary.drops, 2)
        XCTAssertEqual(summary.p999Ns, 0)
        XCTAssertEqual(summary.longestGapNs, 0)
    }

    private func arrival(_ sequence: UInt16, _ ns: UInt64) -> StreamArrival {
        StreamArrival(sequence: sequence, ns: ns)
    }
}
