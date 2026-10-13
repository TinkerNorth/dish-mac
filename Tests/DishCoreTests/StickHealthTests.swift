// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import XCTest
@testable import DishCore

/// The stick tests' math, the desktops' and Android's cases: drift is the
/// mean resting offset, the dead zone has headroom and bounds, the rim sweep
/// needs most of the circle before it judges roundness, and the bench runs a
/// test on virtual time until its capture ends.
final class StickHealthTests: XCTestCase {

    private func onCircle(_ degrees: Int, radius: Float) -> StickSample {
        let rad = Double(degrees) * .pi / 180
        return StickSample(x: Float(cos(rad)) * radius, y: Float(sin(rad)) * radius)
    }

    private func circle(_ radius: Float) -> [StickSample] {
        (0 ..< 360).map { onCircle($0, radius: radius) }
    }

    private func circleWithFlatRight() -> [StickSample] {
        (0 ..< 360).map { degrees in
            let rightQuadrant = degrees < 45 || degrees > 315
            return onCircle(degrees, radius: rightQuadrant ? 0.7 : 1.0)
        }
    }

    // MARK: - Drift and the dead zone

    func testTheDriftOfAnEmptyCaptureIsZero() {
        XCTAssertEqual(stickDrift([]), 0)
    }

    func testDriftAveragesTheRestingOffsetsDistanceFromCentre() {
        let resting = [StickSample](repeating: StickSample(x: 0.06, y: 0.08), count: 10)
        XCTAssertEqual(stickDrift(resting), 0.1, accuracy: 0.0001)
    }

    func testTheSuggestedDeadZoneGivesHeadroomOverTheDriftInWholePercent() {
        XCTAssertEqual(suggestedDeadzone(drift: 0.10), 0.15, accuracy: 0.0001)
        XCTAssertEqual(suggestedDeadzone(drift: 0.071), 0.11, accuracy: 0.0001)
    }

    func testTheSuggestedDeadZoneIsFlooredAtSensorNoiseAndCappedForAFaultyStick() {
        XCTAssertEqual(suggestedDeadzone(drift: 0), 0.04, accuracy: 0.0001)
        XCTAssertEqual(suggestedDeadzone(drift: 0.9), 0.30, accuracy: 0.0001)
    }

    // MARK: - The envelope and the rim

    func testTheEnvelopeTracksEachAxisExtremes() {
        let envelope = stickEnvelope([
            StickSample(x: -0.9, y: 0.1), StickSample(x: 0.95, y: 0), StickSample(x: 0, y: -0.85), StickSample(x: 0.1, y: 0.92)
        ])
        XCTAssertEqual(envelope.minX, -0.9)
        XCTAssertEqual(envelope.maxX, 0.95)
        XCTAssertEqual(envelope.minY, -0.85)
        XCTAssertEqual(envelope.maxY, 0.92)
    }

    func testACleanFullCircleHasAlmostNoCircularityError() throws {
        let error = try XCTUnwrap(stickEnvelope(circle(0.98)).circularityError)
        XCTAssertLessThan(error, 0.01)
    }

    func testAFlatSpotOnOneSideShowsAsCircularityError() throws {
        let error = try XCTUnwrap(stickEnvelope(circleWithFlatRight()).circularityError)
        XCTAssertGreaterThan(error, 0.15)
    }

    func testAnUnfinishedSweepGivesNoCircularityVerdict() {
        let arc = (0 ..< 60).map { onCircle($0, radius: 1) }
        XCTAssertNil(stickEnvelope(arc).circularityError, "only the top-right arc: most buckets are never visited")
    }

    func testInnerTravelDoesNotCountTowardTheRim() {
        XCTAssertNil(stickEnvelope(circle(0.3)).circularityError, "a full circle at 30% is the user wiggling, not the gate")
    }

    func testARimThatNeverMovedFromCentreGivesNoVerdict() {
        var sweep = RimSweep()
        sweep.seen = [Bool](repeating: true, count: StickHealth.rimBuckets)
        XCTAssertNil(sweep.circularityError)
    }

    func testASweepOneBucketShortOfAVerdictGivesNoneAndOneMoreGivesOne() {
        var sweep = RimSweep()
        sweep.reach = [Float](repeating: 1, count: StickHealth.rimBuckets)
        let shortOfVerdict = StickHealth.rimBucketsForVerdict - 1
        for index in 0 ..< shortOfVerdict {
            sweep.seen[index] = true
        }
        XCTAssertNil(sweep.circularityError)
        sweep.seen[shortOfVerdict] = true
        XCTAssertNotNil(sweep.circularityError)
    }

    func testTheRimBucketsRunRoundTheCircleFromStraightLeft() {
        let buckets = StickHealth.rimBuckets
        XCTAssertEqual(RimSweep.bucket(of: StickSample(x: -1, y: 0)), buckets - 1, "straight left sits on the seam")
        XCTAssertEqual(RimSweep.bucket(of: StickSample(x: 0, y: -1)), buckets / 4)
        XCTAssertEqual(RimSweep.bucket(of: StickSample(x: 1, y: 0)), buckets / 2)
        XCTAssertEqual(RimSweep.bucket(of: StickSample(x: 0, y: 1)), 3 * buckets / 4)
    }

    func testTheWorstRailIsTheOneTheStickReachesLeast() {
        XCTAssertEqual(StickEnvelope(minX: -0.9, maxX: 0.95, minY: -0.7, maxY: 0.92).worstReach, 0.7)
        XCTAssertEqual(StickEnvelope(minX: 0.1, maxX: 0.95, minY: -0.7, maxY: 0.92).worstReach, 0, "a rail never reached floors at zero")
    }

    // MARK: - A test on virtual time

    func testARunningTestCountsOneAboveItsWholeSecondsLeft() {
        let test = StickTest(kind: .drift, startMs: 1000)
        XCTAssertEqual(test.secondsLeft(at: 1500), 3)
        XCTAssertEqual(test.secondsLeft(at: 2000), 3)
        XCTAssertEqual(test.secondsLeft(at: 3999), 1)
    }

    func testATestFinishesWhenItsCaptureTimeRunsOut() {
        let drift = StickTest(kind: .drift, startMs: 0)
        XCTAssertFalse(drift.finished(at: StickHealth.driftCaptureMs - 1))
        XCTAssertTrue(drift.finished(at: StickHealth.driftCaptureMs))
        let range = StickTest(kind: .range, startMs: 0)
        XCTAssertFalse(range.finished(at: StickHealth.rangeCaptureMs - 1))
        XCTAssertTrue(range.finished(at: StickHealth.rangeCaptureMs))
        XCTAssertEqual(StickTestKind.drift.captureMs, 3000)
        XCTAssertEqual(StickTestKind.range.captureMs, 8000)
    }

    func testADriftTestReportsBothSticksAndADeadZoneForTheWorseOne() {
        var test = StickTest(kind: .drift, startMs: 0)
        for _ in 0 ..< 20 {
            test.add(left: StickSample(x: 0.06, y: 0.08), right: StickSample(x: 0, y: 0.2))
        }
        let result = test.result()
        XCTAssertEqual(result.kind, .drift)
        XCTAssertEqual(result.samples, 20)
        XCTAssertEqual(result.driftLeft, 0.1, accuracy: 0.0001)
        XCTAssertEqual(result.driftRight, 0.2, accuracy: 0.0001)
        XCTAssertEqual(result.suggestedDeadzone, 0.30, accuracy: 0.0001)
    }

    func testARangeTestReportsEachSticksReachAndRoundness() throws {
        var test = StickTest(kind: .range, startMs: 0)
        let left = circle(1.0)
        let right = circleWithFlatRight()
        for index in left.indices {
            test.add(left: left[index], right: right[index])
        }
        let result = test.result()
        XCTAssertEqual(result.kind, .range)
        XCTAssertEqual(result.samples, 360)
        XCTAssertEqual(result.reachLeft, 1.0, accuracy: 0.001)
        XCTAssertEqual(result.reachRight, 0.7071, accuracy: 0.001, "the flat quadrant's edges still reach the rail at 45 degrees")
        XCTAssertLessThan(try XCTUnwrap(result.circularityLeft), 0.01)
        XCTAssertGreaterThan(try XCTUnwrap(result.circularityRight), 0.15)
    }

    // MARK: - The bench

    func testTheBenchIsIdleUntilATestStarts() {
        let bench = StickBench()
        XCTAssertEqual(bench.phase, .idle)
        XCTAssertNil(bench.result)
        XCTAssertEqual(bench.kind, .drift)
    }

    func testAStartedTestRunsCountingDownUntilItsCaptureTimeEnds() {
        var bench = StickBench()
        bench.start(.range, nowMs: 1000)
        bench.sample(left: StickSample(x: 1, y: 0), right: StickSample(x: 0, y: 1))
        bench.advance(nowMs: 2000)
        XCTAssertEqual(bench.phase, .running)
        XCTAssertEqual(bench.kind, .range)
        XCTAssertEqual(bench.secondsLeft(at: 2000), 8)
        XCTAssertNil(bench.result)
    }

    func testThePollThatReachesATestsEndLeavesItsResult() {
        var bench = StickBench()
        bench.start(.drift, nowMs: 0)
        for _ in 0 ..< 5 {
            bench.sample(left: StickSample(x: 0.06, y: 0.08), right: .centre)
        }
        bench.advance(nowMs: StickHealth.driftCaptureMs)
        XCTAssertEqual(bench.phase, .done)
        XCTAssertEqual(bench.kind, .drift)
        XCTAssertEqual(bench.secondsLeft(at: StickHealth.driftCaptureMs), 0)
        XCTAssertEqual(bench.result?.samples, 5)
        XCTAssertEqual(bench.result?.driftLeft ?? 0, 0.1, accuracy: 0.0001)
    }

    func testTheBenchTakesNoSamplesWhileNoTestRunsAndAStartReplacesTheLast() {
        var bench = StickBench()
        bench.sample(left: StickSample(x: 0.5, y: 0.5), right: StickSample(x: 0.5, y: 0.5))
        bench.start(.drift, nowMs: 0)
        bench.advance(nowMs: StickHealth.driftCaptureMs)
        XCTAssertEqual(bench.result?.samples, 0, "the sample before the start never counted")
        bench.start(.range, nowMs: 5000)
        XCTAssertEqual(bench.phase, .running)
        XCTAssertEqual(bench.kind, .range, "the running test speaks before the last result")
    }
}
