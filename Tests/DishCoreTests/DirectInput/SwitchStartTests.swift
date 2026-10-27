// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import XCTest

/// A Switch-family pad on USB streams its full reports only after the USB
/// handshake, the timeout disable and "full report mode", which macOS's
/// driver does not leave in place for the N64. The packets are dish-android's
/// (`usb_parsers.cpp`, kSwitchInitPackets); the watch decides when to send
/// them: never to a pad that streams, after a grace for Apple's own
/// handshake, one packet per tick, and less often while nothing helps.
final class SwitchStartTests: XCTestCase {
    private let opened: Int64 = 10000

    // MARK: - The packets

    func testTheHandshakeIsAndroidsFullUsbPacket() {
        let expected = [UInt8(0x80), 0x02] + [UInt8](repeating: 0, count: 62)
        XCTAssertEqual(switchStartPacket(.handshake), expected)
    }

    func testTheTimeoutDisableIsAndroidsFullUsbPacket() {
        let expected = [UInt8(0x80), 0x04] + [UInt8](repeating: 0, count: 62)
        XCTAssertEqual(switchStartPacket(.disableTimeout), expected)
    }

    func testFullReportModeIsTheSubcommandThreeWithArgumentThirtyBehindNeutralRumble() {
        let subcommand: [UInt8] = [0x01, 0x00, 0x00, 0x01, 0x40, 0x40, 0x00, 0x01, 0x40, 0x40, 0x03, 0x30]
        let expected = subcommand + [UInt8](repeating: 0, count: 52)
        XCTAssertEqual(switchStartPacket(.fullReportMode), expected)
    }

    func testEveryPacketIsOneUsbPacketLongAndNamesItsReportInItsFirstByte() {
        for step in SwitchStartStep.allCases {
            let packet = switchStartPacket(step)
            XCTAssertEqual(packet.count, switchStartPacketBytes, "\(step)")
            XCTAssertEqual(switchStartReportId(step), packet[0], "\(step)")
        }
    }

    func testTheStepsRunHandshakeThenTimeoutThenReportMode() {
        XCTAssertEqual(SwitchStartStep.handshake.next, .disableTimeout)
        XCTAssertEqual(SwitchStartStep.disableTimeout.next, .fullReportMode)
        XCTAssertNil(SwitchStartStep.fullReportMode.next)
    }

    // MARK: - When to send

    func testAPadThatAlreadyStreamsIsNeverStarted() {
        let watch = SwitchStreamWatch(openedMs: opened)
        XCTAssertEqual(watch.due(lastFullReportMs: opened + 100, nowMs: opened + 150), .streaming)
    }

    func testASilentPadWaitsOutTheGraceForApplesOwnHandshake() {
        let watch = SwitchStreamWatch(openedMs: opened)
        let lastWaitMs = opened + SwitchStreamRule.graceMs - 1
        XCTAssertEqual(watch.due(lastFullReportMs: nil, nowMs: lastWaitMs), .wait)
        XCTAssertEqual(watch.due(lastFullReportMs: nil, nowMs: opened + SwitchStreamRule.graceMs), .send(.handshake))
    }

    func testTheSequenceGoesOutOnePacketPerTick() {
        var watch = SwitchStreamWatch(openedMs: opened)
        let start = opened + SwitchStreamRule.graceMs
        watch.noteSent(.handshake, nowMs: start)
        XCTAssertEqual(watch.due(lastFullReportMs: nil, nowMs: start + 250), .send(.disableTimeout))
        watch.noteSent(.disableTimeout, nowMs: start + 250)
        XCTAssertEqual(watch.due(lastFullReportMs: nil, nowMs: start + 500), .send(.fullReportMode))
        watch.noteSent(.fullReportMode, nowMs: start + 500)
        XCTAssertEqual(watch.due(lastFullReportMs: nil, nowMs: start + 750), .wait)
    }

    func testASequenceThatBroughtNoStreamIsRepeatedAfterTheRetryInterval() {
        var watch = sentOneSequence(at: opened + SwitchStreamRule.graceMs)
        let start = opened + SwitchStreamRule.graceMs
        XCTAssertEqual(watch.due(lastFullReportMs: nil, nowMs: start + SwitchStreamRule.retryMs - 1), .wait)
        XCTAssertEqual(watch.due(lastFullReportMs: nil, nowMs: start + SwitchStreamRule.retryMs), .send(.handshake))
        watch.noteSent(.handshake, nowMs: start + SwitchStreamRule.retryMs)
        XCTAssertEqual(watch.startsWithoutStream, 2)
    }

    func testAfterTheQuickStartsTheWatchRetriesSlowly() {
        var watch = SwitchStreamWatch(openedMs: opened)
        var start = opened + SwitchStreamRule.graceMs
        for _ in 0 ..< SwitchStreamRule.quickStarts {
            sendSequence(&watch, at: start)
            start += SwitchStreamRule.retryMs
        }
        let lastStart = start - SwitchStreamRule.retryMs
        XCTAssertEqual(watch.due(lastFullReportMs: nil, nowMs: lastStart + SwitchStreamRule.retryMs), .wait)
        XCTAssertEqual(watch.due(lastFullReportMs: nil, nowMs: lastStart + SwitchStreamRule.slowRetryMs), .send(.handshake))
    }

    func testAStreamAfterAStartResetsTheCountSoALaterStallRetriesQuickly() {
        var watch = sentOneSequence(at: opened + SwitchStreamRule.graceMs)
        watch.noteStreaming()
        XCTAssertEqual(watch.startsWithoutStream, 0)
    }

    func testAStreamThatStallsIsStartedAgain() {
        let watch = SwitchStreamWatch(openedMs: opened)
        let lastReport = opened + 5000
        XCTAssertEqual(watch.due(lastFullReportMs: lastReport, nowMs: lastReport + SwitchStreamRule.stallMs - 1), .streaming)
        XCTAssertEqual(watch.due(lastFullReportMs: lastReport, nowMs: lastReport + SwitchStreamRule.stallMs), .send(.handshake))
    }

    func testAStreamThatStartsMidSequenceDropsTheRestOfIt() {
        var watch = SwitchStreamWatch(openedMs: opened)
        let start = opened + SwitchStreamRule.graceMs
        watch.noteSent(.handshake, nowMs: start)
        XCTAssertEqual(watch.due(lastFullReportMs: start + 100, nowMs: start + 250), .streaming)
        watch.noteStreaming()
        XCTAssertEqual(watch.due(lastFullReportMs: start + 100, nowMs: start + SwitchStreamRule.stallMs + 100), .send(.handshake))
    }

    // MARK: - Helpers

    private func sentOneSequence(at start: Int64) -> SwitchStreamWatch {
        var watch = SwitchStreamWatch(openedMs: opened)
        sendSequence(&watch, at: start)
        return watch
    }

    private func sendSequence(_ watch: inout SwitchStreamWatch, at start: Int64) {
        watch.noteSent(.handshake, nowMs: start)
        watch.noteSent(.disableTimeout, nowMs: start + 250)
        watch.noteSent(.fullReportMode, nowMs: start + 500)
    }
}
