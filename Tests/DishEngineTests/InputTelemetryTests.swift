// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import XCTest
@testable import DishEngine

/// The telemetry the Home and Controllers footers and the wire line read:
/// every report the processor publishes is an event, every report the
/// router hands a sink is a send, and the source turns the counts into
/// rates while a page that shows them is on screen.
@MainActor
final class InputTelemetryTests: XCTestCase {

    func testEveryPublishedReportIsAnEventOfItsPad() {
        let processor = GamepadInputProcessor()
        processor.publish(deviceId: "a", state: GamepadReport())
        processor.publish(deviceId: "a", state: GamepadReport())
        processor.publish(deviceId: "b", state: GamepadReport())
        XCTAssertEqual(processor.tally.snapshot().reports, ["a": 2, "b": 1])
    }

    func testEveryAdmittedMotionSampleCountsAndAThinnedOneDoesNot() {
        let processor = GamepadInputProcessor()
        let sample = MotionSample(gyroX: 0, gyroY: 0, gyroZ: 0, accelX: 0, accelY: 0, accelZ: 0)
        processor.publishMotion(deviceId: "a", sample: sample, nowNs: 1_000_000_000)
        processor.publishMotion(deviceId: "a", sample: sample, nowNs: 1_000_000_001)
        processor.publishMotion(deviceId: "a", sample: sample, nowNs: 1_010_000_000)
        XCTAssertEqual(processor.tally.snapshot().motion, ["a": 2])
    }

    func testOnlyARoutedReportIsASend() {
        let routing = InputRouting()
        routing.sendReport("unbound", GamepadReport())
        XCTAssertEqual(routing.sent.current(), 0, "a pad with no route sends nothing")
        var snapshot = RoutingSnapshot()
        snapshot.bySlot["pad"] = Route(sink: DiscardingSink(), flags: ForwardingFlags())
        routing.table.set(snapshot)
        routing.sendReport("pad", GamepadReport())
        XCTAssertEqual(routing.sent.current(), 1)
    }

    func testTheRatesAreTheCountsOverTheInterval() {
        var rates = TelemetryRates()
        let first = rates.sample(InputCounts(reports: ["a": 0], motion: ["a": 0], sends: 0), nowUs: 0)
        XCTAssertEqual(first, InputTelemetry(pads: ["a": PadRates(reportHz: 0, motionHz: 0)]), "the first sample anchors")
        let second = rates.sample(InputCounts(reports: ["a": 250], motion: ["a": 100], sends: 250), nowUs: 1_000_000)
        XCTAssertEqual(second.eventsPerSecond, 250)
        XCTAssertEqual(second.sendsPerSecond, 250)
        XCTAssertEqual(second.totalSent, 250)
        XCTAssertEqual(second.pads["a"], PadRates(reportHz: 250, motionHz: 100))
    }

    func testAPadThatLeftDropsOutOfTheRates() {
        var rates = TelemetryRates()
        _ = rates.sample(InputCounts(reports: ["a": 0, "b": 0], motion: [:], sends: 0), nowUs: 0)
        let next = rates.sample(InputCounts(reports: ["a": 10], motion: [:], sends: 0), nowUs: 1_000_000)
        XCTAssertNil(next.pads["b"])
        XCTAssertEqual(next.pads["a"]?.reportHz, 10)
    }

    func testAPadReportsWhileItsCountMovesAndItsFirstSampleIsTheBaseline() {
        var rates = TelemetryRates()
        XCTAssertEqual(rates.sample(InputCounts(reports: ["a": 5, "b": 9]), nowUs: 0).reporting, [], "a baseline lights nothing")
        XCTAssertEqual(rates.activity(["a": 6, "b": 9]), ["a"])
        XCTAssertEqual(rates.activity(["a": 6, "b": 9]), [], "still pads go dark")
        XCTAssertEqual(rates.sample(InputCounts(reports: ["a": 6, "b": 12]), nowUs: 1_000_000).reporting, ["b"])
    }

    func testTheQuarterTicksPublishOnlyTheActivityAndEveryFourthTheRates() {
        let source = TelemetrySource()
        var counts = InputCounts(reports: ["a": 0])
        var ridden = 0
        source.use(counts: { counts }, clockUs: { 0 })
        source.useTick { ridden += 1 }
        source.refresh()
        counts.reports["a"] = 3
        source.tick()
        XCTAssertEqual(source.state.reporting, ["a"])
        XCTAssertEqual(ridden, 1, "a quarter tick rides nothing")
        source.tick()
        source.tick()
        XCTAssertEqual(source.state.reporting, [])
        source.tick()
        XCTAssertEqual(ridden, 2, "the fourth tick is the rates'")
    }

    func testTheSourceTicksWhileAPageShowsAndStopsWhenTheLastLeaves() {
        let source = TelemetrySource()
        XCTAssertFalse(source.isTicking)
        source.show()
        source.show()
        XCTAssertTrue(source.isTicking)
        source.hide()
        XCTAssertTrue(source.isTicking, "another page still shows")
        source.hide()
        XCTAssertFalse(source.isTicking)
        source.hide()
        XCTAssertFalse(source.isTicking, "an extra hide never goes below none")
    }

    func testARefreshReadsTheCountsThroughTheProvider() {
        let source = TelemetrySource()
        var counts = InputCounts(reports: ["a": 0], motion: [:], sends: 0)
        var now: UInt64 = 0
        source.use(counts: { counts }, clockUs: { now })
        source.refresh()
        counts = InputCounts(reports: ["a": 60], motion: [:], sends: 60)
        now = 1_000_000
        source.refresh()
        XCTAssertEqual(source.state.eventsPerSecond, 60)
        XCTAssertEqual(source.state.totalSent, 60)
    }
}

/// A sink that takes every stream and keeps nothing.
private final class DiscardingSink: InputSink {
    func sendReport(_: GamepadReport) {}
    func sendMotion(_: MotionSample, timestampDeltaUs _: UInt32) {}
    func sendTouchpad(sample _: TouchpadSample, eventTimeMs _: UInt32) {}
    func sendBattery(level _: UInt8, status _: BatteryStatus) {}
}
