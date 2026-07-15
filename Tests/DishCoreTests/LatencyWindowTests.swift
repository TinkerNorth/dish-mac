// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// Pins the pure heartbeat-RTT latency window: the ping-clock arming rule
// (single-in-flight guard + 5 s loss reclaim), the 64-sample sliding window
// with its validity clamp, the median/2 one-way estimate (android's
// nearest-rank quantile — upper-middle for an even count), and the
// deterministic "~3.4 ms" display formatting. Pure, no clock. Ports
// dish-linux test_latency_window.cpp (dish-android #138 policy).

import DishCore
import XCTest

final class LatencyWindowTests: XCTestCase {

    // MARK: - shouldArmPing / armPing: in-flight guard + loss reclaim

    func testArmsWhenNoPingIsOutstanding() {
        let window = LatencyWindow()
        XCTAssertTrue(window.shouldArmPing(nowMs: 1000))
    }

    func testHoldsTheClockWhileAPingIsInFlight() {
        // Overwriting would pair the in-flight ping's late ack with the newer
        // stamp and read artificially low.
        var window = LatencyWindow()
        window.armPing(nowMs: 1000)
        XCTAssertFalse(window.shouldArmPing(nowMs: 1001))
        XCTAssertFalse(window.shouldArmPing(nowMs: 1000 + Int64(LatencyWindow.rttMaxMs) - 1))
    }

    func testReclaimsALostPingPastTheValidityWindow() {
        // Past 5 s the ping is lost, not in flight — the next send re-arms.
        var window = LatencyWindow()
        window.armPing(nowMs: 1000)
        XCTAssertTrue(window.shouldArmPing(nowMs: 1000 + Int64(LatencyWindow.rttMaxMs)))
        XCTAssertTrue(window.shouldArmPing(nowMs: 1000 + 2 * Int64(LatencyWindow.rttMaxMs)))
    }

    func testArmPingRefusesToOverwriteAnInFlightStamp() {
        var window = LatencyWindow()
        window.armPing(nowMs: 1000)
        // A second arm attempt inside the window is ignored: the ack at 1007
        // pairs with the ORIGINAL stamp (RTT 7), not the newer one.
        window.armPing(nowMs: 1005)
        window.ackReceived(nowMs: 1007)
        XCTAssertEqual(window.p50OneWayMs(), 3.5)
    }

    func testAckPairsWithTheInFlightPingAndDuplicatesAreIgnored() {
        var window = LatencyWindow()
        window.armPing(nowMs: 1000)
        window.ackReceived(nowMs: 1010)
        XCTAssertEqual(window.sampleCount, 1)
        XCTAssertEqual(window.p50OneWayMs(), 5.0)
        // A duplicate ack finds no outstanding stamp — no double-count.
        window.ackReceived(nowMs: 1020)
        XCTAssertEqual(window.sampleCount, 1)
    }

    func testAReclaimedPingsStaleAckIsDroppedByTheValidityClamp() {
        var window = LatencyWindow()
        window.armPing(nowMs: 1000)
        // Answered after the loss cap: the RTT (6000 ms) is dropped rather
        // than skewing the window; the clock is still consumed.
        window.ackReceived(nowMs: 7000)
        XCTAssertEqual(window.sampleCount, 0)
        XCTAssertTrue(window.shouldArmPing(nowMs: 7001))
    }

    // MARK: - Window: count + median/2

    func testEmptyReadsZeroSamplesAndNilLatency() {
        let window = LatencyWindow()
        XCTAssertEqual(window.sampleCount, 0)
        XCTAssertNil(window.p50OneWayMs())
    }

    func testASingleRttSampleReadsAsItsHalf() {
        var window = LatencyWindow()
        window.recordRtt(ms: 6.8)
        XCTAssertEqual(window.sampleCount, 1)
        XCTAssertEqual(window.p50OneWayMs(), 3.4)
    }

    func testOddCountTakesTheMiddleSample() {
        var window = LatencyWindow()
        window.recordRtt(ms: 10.0)
        window.recordRtt(ms: 2.0)
        window.recordRtt(ms: 4.0)
        // sorted {2, 4, 10} -> median 4 -> one-way 2.
        XCTAssertEqual(window.sampleCount, 3)
        XCTAssertEqual(window.p50OneWayMs(), 2.0)
    }

    func testEvenCountTakesTheUpperMiddleNearestRank() {
        var window = LatencyWindow()
        window.recordRtt(ms: 2.0)
        window.recordRtt(ms: 4.0)
        // android's q(0.50) indexes round(0.5 * (n - 1)) of the sorted window:
        // for n=2 that is sample 1 (the upper middle), NOT the pair's mean.
        XCTAssertEqual(window.p50OneWayMs(), 2.0)
        window.recordRtt(ms: 1.0)
        window.recordRtt(ms: 3.0)
        // sorted {1, 2, 3, 4}, n=4 -> index 2 -> 3 -> one-way 1.5.
        XCTAssertEqual(window.p50OneWayMs(), 1.5)
    }

    func testSlidesAtCapacityEvictingTheOldestSample() {
        var window = LatencyWindow()
        window.recordRtt(ms: 1000.0) // will be evicted by the pushes below
        for _ in 0 ..< LatencyWindow.capacity {
            window.recordRtt(ms: 10.0)
        }
        XCTAssertEqual(window.sampleCount, LatencyWindow.capacity)
        // The 1000 ms outlier slid out, so the median answers "now": all-10 -> 5.
        XCTAssertEqual(window.p50OneWayMs(), 5.0)
    }

    func testRejectsOutOfRangeSamples() {
        var window = LatencyWindow()
        window.recordRtt(ms: -0.1) // clock retrograde
        window.recordRtt(ms: 5000.0) // at the loss cap — a reclaimed ping's stale ack
        window.recordRtt(ms: 6000.0) // beyond it
        XCTAssertEqual(window.sampleCount, 0)
        window.recordRtt(ms: 4999.9) // just inside stays
        XCTAssertEqual(window.sampleCount, 1)
    }

    func testResetDropsEverySample() {
        var window = LatencyWindow()
        window.recordRtt(ms: 10.0)
        window.recordRtt(ms: 20.0)
        window.reset()
        XCTAssertEqual(window.sampleCount, 0)
        XCTAssertNil(window.p50OneWayMs())
        // Fresh pushes measure the new session only.
        window.recordRtt(ms: 4.0)
        XCTAssertEqual(window.p50OneWayMs(), 2.0)
    }

    func testResetAlsoDropsTheInFlightPingClock() {
        // setConnectionParams semantics: a stale in-flight stamp must not pair
        // with the new session's first ack.
        var window = LatencyWindow()
        window.armPing(nowMs: 1000)
        window.reset()
        window.ackReceived(nowMs: 1004)
        XCTAssertEqual(window.sampleCount, 0)
        XCTAssertTrue(window.shouldArmPing(nowMs: 1005))
    }

    // MARK: - formatLatencyMs: deterministic one-decimal display

    func testFormatIsOneDecimalHalfAwayFromZero() {
        XCTAssertEqual(formatLatencyMs(3.4), "~3.4 ms")
        XCTAssertEqual(formatLatencyMs(3.44), "~3.4 ms")
        XCTAssertEqual(formatLatencyMs(12.06), "~12.1 ms")
        XCTAssertEqual(formatLatencyMs(5.0), "~5.0 ms")
        XCTAssertEqual(formatLatencyMs(0.24), "~0.2 ms")
    }

    func testFormatIsNeverNegative() {
        XCTAssertEqual(formatLatencyMs(0.0), "~0.0 ms")
        XCTAssertEqual(formatLatencyMs(-3.0), "~0.0 ms")
    }
}
