// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import XCTest

/// A Switch-family pad on USB streams its full reports only after Dish's
/// start sequence, which macOS's driver never sends. The watch decides when
/// to send it: never to a pad that streams, after a grace for Apple's own
/// handshake, one packet per tick, and less often while nothing helps.
final class SwitchStartTests: XCTestCase {
    private let opened: Int64 = 10000
    private let tickMs: Int64 = 250

    // MARK: - The packets

    func testTheHandshakeIsAFullUsbPacket() {
        XCTAssertEqual(switchStartPacket(.handshake), usbPacket([0x80, 0x02]))
    }

    func testTheSwitchToThreeMegabitIsAFullUsbPacket() {
        XCTAssertEqual(switchStartPacket(.highSpeed), usbPacket([0x80, 0x03]))
    }

    func testTheHandshakeAtThreeMegabitIsTheHandshakeAgain() {
        XCTAssertEqual(switchStartPacket(.handshakeAtHighSpeed), switchStartPacket(.handshake))
    }

    func testTheTimeoutDisableIsAFullUsbPacket() {
        XCTAssertEqual(switchStartPacket(.disableTimeout), usbPacket([0x80, 0x04]))
    }

    func testFullReportModeIsTheSubcommandThreeWithArgumentThirtyBehindNeutralRumble() {
        XCTAssertEqual(switchStartPacket(.fullReportMode), usbPacket(CapturedSwitchPro.fullReportModeSubcommand))
    }

    func testEveryPacketIsOneUsbPacketLongAndNamesItsReportInItsFirstByte() {
        for step in SwitchStartStep.allCases {
            let packet = switchStartPacket(step)
            XCTAssertEqual(packet.count, switchStartPacketBytes, "\(step)")
            XCTAssertEqual(switchStartReportId(step), packet[0], "\(step)")
        }
    }

    /// Linux's hid-nintendo and SDL open every Switch pad on USB in this
    /// order; dish-android's handshake, timeout disable and report mode
    /// leave a Pro silent.
    func testTheSequenceIsTheHandshakeAtThreeMegabitThenTheTimeoutDisableThenFullReportMode() {
        let expected = [[0x80, 0x02], [0x80, 0x03], [0x80, 0x02], [0x80, 0x04], CapturedSwitchPro.fullReportModeSubcommand].map(usbPacket)
        XCTAssertEqual(oneSequence().map(\.packet), expected)
    }

    // MARK: - The Pro, as it answered on a Mac

    func testAQuietProStreamsOnceTheTimeoutDisableFollowsTheHandshakeAtThreeMegabit() {
        var pad = CapturedSwitchPro()
        for sent in oneSequence() {
            pad.receive(sent.packet)
        }
        XCTAssertTrue(pad.streams, "the Pro took \(pad.received.count) packets and stayed silent")
    }

    func testTheProsAnswersBeforeItStreamsAreNoFullReports() {
        let answers = [CapturedSwitchPro.handshakeReply, CapturedSwitchPro.highSpeedReply, CapturedSwitchPro.subcommandReply]
        XCTAssertEqual(answers.map(isFullReport), [false, false, false])
        XCTAssertTrue(isFullReport(CapturedSwitchPro.idleFullReport))
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

    func testTheSequenceGoesOutOnePacketPerTickThenWaits() {
        let sequence = oneSequence()
        let start = opened + SwitchStreamRule.graceMs
        XCTAssertEqual(sequence.map(\.atMs), sequence.indices.map { start + Int64($0) * tickMs })
        let watch = sentOneSequence(at: start)
        XCTAssertEqual(watch.due(lastFullReportMs: nil, nowMs: start + Int64(sequence.count) * tickMs), .wait)
    }

    func testTheHandshakeAtThreeMegabitStartsNoNewSequence() {
        var watch = SwitchStreamWatch(openedMs: opened)
        let start = opened + SwitchStreamRule.graceMs
        watch.noteSent(.handshake, nowMs: start)
        watch.noteSent(.highSpeed, nowMs: start + tickMs)
        watch.noteSent(.handshakeAtHighSpeed, nowMs: start + 2 * tickMs)
        XCTAssertEqual(watch.startsWithoutStream, 1)
        XCTAssertEqual(watch.lastStartMs, start)
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
        XCTAssertEqual(watch.due(lastFullReportMs: start + 100, nowMs: start + tickMs), .streaming)
        watch.noteStreaming()
        XCTAssertEqual(watch.due(lastFullReportMs: start + 100, nowMs: start + SwitchStreamRule.stallMs + 100), .send(.handshake))
    }

    // MARK: - Helpers

    /// The packets one sequence sends to a silent pad, as the reader's tick
    /// would collect them, with the time each went out.
    private func oneSequence() -> [SentPacket] {
        var watch = SwitchStreamWatch(openedMs: opened)
        var nowMs = opened + SwitchStreamRule.graceMs
        var sent: [SentPacket] = []
        while case let .send(step) = watch.due(lastFullReportMs: nil, nowMs: nowMs) {
            sent.append(SentPacket(packet: switchStartPacket(step), atMs: nowMs))
            watch.noteSent(step, nowMs: nowMs)
            nowMs += tickMs
        }
        return sent
    }

    private func sentOneSequence(at start: Int64) -> SwitchStreamWatch {
        var watch = SwitchStreamWatch(openedMs: opened)
        sendSequence(&watch, at: start)
        return watch
    }

    private func sendSequence(_ watch: inout SwitchStreamWatch, at start: Int64) {
        var step: SwitchStartStep? = .handshake
        var nowMs = start
        while let current = step {
            watch.noteSent(current, nowMs: nowMs)
            step = current.next
            nowMs += tickMs
        }
    }

    private func usbPacket(_ bytes: [UInt8]) -> [UInt8] {
        bytes + [UInt8](repeating: 0, count: switchStartPacketBytes - bytes.count)
    }

    private func isFullReport(_ bytes: [UInt8]) -> Bool {
        bytes.withUnsafeBufferPointer(isSwitchInputReport)
    }
}

private struct SentPacket {
    let packet: [UInt8]
    let atMs: Int64
}
