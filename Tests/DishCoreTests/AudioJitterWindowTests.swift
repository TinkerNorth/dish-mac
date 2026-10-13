// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import XCTest
@testable import DishCore

/// The window the satellite and dish-android keep, event for event: their
/// own suites spell the same sequences as "G12/F P13 P14", "P65535 P0" and
/// "G11 G12 P36".
final class AudioJitterWindowTests: XCTestCase {

    private func frame(_ seq: UInt16) -> AudioFrame {
        AudioFrame(controllerIndex: 0, seq: seq, opus: Data([UInt8(seq & 0xFF), UInt8(seq >> 8)]))
    }

    private func packet(_ seq: UInt16) -> PlayoutEvent {
        .packet(Data([UInt8(seq & 0xFF), UInt8(seq >> 8)]))
    }

    func testInOrderAudioPlaysAtOnceWithNoAddedLatency() {
        var lane = AudioJitterWindow()
        XCTAssertEqual(lane.push(frame(10)), [packet(10)], "the first packet primes the window and plays")
        XCTAssertEqual(lane.push(frame(11)), [packet(11)])
        XCTAssertEqual(lane.push(frame(12)), [packet(12)])
        XCTAssertEqual(lane.played, 3)
        XCTAssertEqual(lane.held, [:])
    }

    func testAPacketOneAheadIsHeldUntilItsPredecessorArrives() {
        var lane = AudioJitterWindow()
        _ = lane.push(frame(1))
        XCTAssertEqual(lane.push(frame(3)), [], "one ahead is not yet a loss")
        XCTAssertEqual(lane.push(frame(2)), [packet(2), packet(3)], "the late one plays, then the held one")
        XCTAssertEqual(lane.concealed, 0)
    }

    func testALossIsDeclaredTwoAheadWithTheNextPacketAsFecCarrier() {
        var lane = AudioJitterWindow()
        _ = lane.push(frame(11))
        XCTAssertEqual(lane.push(frame(13)), [])
        XCTAssertEqual(lane.push(frame(14)), [.gap(carrier: frame(13).opus), packet(13), packet(14)], "G12/F P13 P14")
        XCTAssertEqual(lane.concealed, 1)
        XCTAssertEqual(lane.push(frame(12)), [.late], "after its slot a frame is noise")
        XCTAssertEqual(lane.lateDrops, 1)
    }

    func testTheSequenceWraps() {
        var lane = AudioJitterWindow()
        _ = lane.push(frame(0xFFFE))
        XCTAssertEqual(lane.push(frame(0x0000)), [], "held across the wrap")
        XCTAssertEqual(lane.push(frame(0xFFFF)), [packet(0xFFFF), packet(0x0000)], "P65535 P0")
        XCTAssertEqual(lane.push(frame(0xFFFD)), [.late])
    }

    func testTwoConcealedFramesInARowThenTheWindowResyncs() {
        var lane = AudioJitterWindow()
        _ = lane.push(frame(10))
        XCTAssertEqual(lane.push(frame(36)), [.gap(carrier: nil), .gap(carrier: nil), packet(36)], "G11 G12 P36")
        XCTAssertEqual(lane.next, 37)
        XCTAssertEqual(lane.consecutiveGaps, 0)
        XCTAssertEqual(lane.push(frame(37)), [packet(37)])
    }

    func testOneArrivalNeverFloodsTheDecoder() {
        XCTAssertEqual(AudioJitterWindow.maxEventsPerPush, 6)
        var lane = AudioJitterWindow()
        _ = lane.push(frame(1))
        let script: [UInt16] = [3, 4, 2, 90, 91, 5, 6, 92, 200, 7, 201, 202, 203, 0, 300]
        for seq in script {
            XCTAssertLessThanOrEqual(lane.push(frame(seq)).count, AudioJitterWindow.maxEventsPerPush, "seq \(seq)")
        }
        XCTAssertGreaterThan(lane.concealed, 0, "the far jumps were concealed and resynced")
    }

    func testResetStartsTheLaneFresh() {
        var lane = AudioJitterWindow()
        _ = lane.push(frame(5))
        lane.reset()
        XCTAssertEqual(lane, AudioJitterWindow())
        XCTAssertEqual(lane.push(frame(100)), [packet(100)])
    }
}
