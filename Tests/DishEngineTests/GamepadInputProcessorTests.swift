// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import XCTest
@testable import DishEngine

final class GamepadInputProcessorTests: XCTestCase {

    // MARK: - Axis scaling

    func testScaleAxisCenterIsZero() {
        XCTAssertEqual(scaleAxis(0, max: 32767), 0)
    }

    func testScaleAxisFullPositive() {
        XCTAssertEqual(scaleAxis(1, max: 32767), 32767)
    }

    func testScaleAxisFullNegative() {
        // -1.0 * 32767 = -32767 (Xbox convention, one short of -32768 floor).
        XCTAssertEqual(scaleAxis(-1, max: 32767), -32767)
    }

    func testScaleAxisClampsOverflow() {
        XCTAssertEqual(scaleAxis(2, max: 32767), Int16.max)
        XCTAssertEqual(scaleAxis(-2, max: 32767), Int16.min)
    }

    // MARK: - Trigger scaling

    func testScaleTriggerBounds() {
        XCTAssertEqual(scaleTrigger(0), 0)
        XCTAssertEqual(scaleTrigger(1), 255)
    }

    func testScaleTriggerRoundsHalfValue() {
        // 0.5 * 255 = 127.5 -> rounded to 128
        XCTAssertEqual(scaleTrigger(0.5), 128)
    }

    func testScaleTriggerClampsOverflow() {
        XCTAssertEqual(scaleTrigger(-1), 0)
        XCTAssertEqual(scaleTrigger(2), 255)
    }

    // MARK: - The record the inspector reads

    func testTheRecordHoldsTheRawAndFilteredReportAndEveryAdmittedSample() throws {
        let processor = GamepadInputProcessor()
        processor.setDeadzones(deviceId: "pad", .init(stickFlat: 3000, triggerFlat: 10))
        let raw = GamepadReport(buttons: 1, lt: 5, rt: 200, lx: 2000, ly: -2000, rx: 9000, ry: 0)
        processor.publish(deviceId: "pad", state: raw)
        let reported = try XCTUnwrap(processor.latestInput("pad"))
        XCTAssertEqual(reported.raw, raw)
        XCTAssertEqual(reported.filtered?.lx, 0, "the dead zone applied for the host")
        XCTAssertEqual(reported.filtered?.rx, 9000)
        XCTAssertEqual(reported.filtered?.lt, 0)
        XCTAssertEqual(reported.reports, 1)
        XCTAssertNil(reported.motion)
        let sample = MotionSample(gyroX: 1, gyroY: 2, gyroZ: 3, accelX: 4, accelY: 5, accelZ: 6)
        let refused = MotionSample(gyroX: 9, gyroY: 9, gyroZ: 9, accelX: 9, accelY: 9, accelZ: 9)
        processor.publishMotion(deviceId: "pad", sample: sample, nowNs: 1_000_000)
        processor.publishMotion(deviceId: "pad", sample: refused, nowNs: 1_000_001)
        XCTAssertEqual(processor.latestInput("pad")?.motion, sample, "a sample the rate limit refused is not recorded")
        XCTAssertEqual(processor.tallySnapshot().motion, ["pad": 1])
        let touch = TouchpadSample(finger0: TouchpadFinger(active: true, id: 3, x: -7, y: 8), finger1: .none, buttonPressed: true)
        processor.publishTouchpad(deviceId: "pad", sample: touch)
        XCTAssertEqual(processor.latestInput("pad")?.touch, touch)
        XCTAssertNil(processor.latestInput("other"), "a pad with no feed has no record")
    }

    // MARK: - Button bitfield (wire contract parity with Android)

    func testButtonBitsMatchXusb() {
        typealias Btn = GamepadInputProcessor.Buttons
        XCTAssertEqual(Btn.dpadUp, 0x0001)
        XCTAssertEqual(Btn.dpadDown, 0x0002)
        XCTAssertEqual(Btn.dpadLeft, 0x0004)
        XCTAssertEqual(Btn.dpadRight, 0x0008)
        XCTAssertEqual(Btn.start, 0x0010)
        XCTAssertEqual(Btn.back, 0x0020)
        XCTAssertEqual(Btn.leftThumb, 0x0040)
        XCTAssertEqual(Btn.rightThumb, 0x0080)
        XCTAssertEqual(Btn.leftShoulder, 0x0100)
        XCTAssertEqual(Btn.rightShoulder, 0x0200)
        XCTAssertEqual(Btn.guide, 0x0400)
        XCTAssertEqual(Btn.faceA, 0x1000)
        XCTAssertEqual(Btn.faceB, 0x2000)
        XCTAssertEqual(Btn.faceX, 0x4000)
        XCTAssertEqual(Btn.faceY, 0x8000)
    }

    // MARK: - Publish sends through the pad's route

    func testPublishSendsTheStateThroughThePadsRoute() {
        let proc = GamepadInputProcessor()
        let recorder = InputRecorder()
        proc.route(recorder.route)
        let state = GamepadInputProcessor.DeviceState(buttons: 0x1234, lt: 10, rt: 20, lx: 100, ly: -200, rx: 300, ry: -400)
        proc.publish(deviceId: "pad-1", state: state)
        XCTAssertEqual(recorder.reports.map(\.id), ["pad-1"])
        XCTAssertEqual(recorder.reports.map(\.report), [state])
        XCTAssertEqual(proc.sent.current(), 1)
    }

    func testAPadWithNoRouteSendsNothing() {
        let proc = GamepadInputProcessor()
        let recorder = InputRecorder()
        proc.route { deviceId in deviceId == "bound" ? recorder.route(deviceId) : nil }
        proc.publish(deviceId: "unbound", state: GamepadReport(buttons: 1))
        XCTAssertTrue(recorder.reports.isEmpty)
        XCTAssertEqual(proc.sent.current(), 0)
        proc.publish(deviceId: "bound", state: GamepadReport(buttons: 1))
        XCTAssertEqual(recorder.reports.map(\.id), ["bound"])
    }

    func testARouteChangeReachesAFeedMadeBeforeIt() {
        let proc = GamepadInputProcessor()
        let feed = proc.feed(for: "pad")
        feed.publish(GamepadReport(buttons: 1))
        let recorder = InputRecorder()
        proc.route(recorder.route)
        feed.publish(GamepadReport(buttons: 2))
        XCTAssertEqual(recorder.reports.map(\.report.buttons), [2], "the route arrives with the next report")
        XCTAssertTrue(proc.feed(for: "pad") === feed, "a pad keeps its feed")
    }

    // MARK: - zeroAndSendAll fans a release-all report to every known device

    func testZeroAndSendAllEmitsReleasedReportPerDevice() {
        let proc = GamepadInputProcessor()
        let recorder = InputRecorder()
        proc.route(recorder.route)
        proc.publish(deviceId: "a", state: .init(buttons: 1, lt: 5, rt: 6, lx: 7, ly: 8, rx: 9, ry: 10))
        proc.publish(deviceId: "b", state: .init(buttons: 2, lt: 11, rt: 12, lx: 13, ly: 14, rx: 15, ry: 16))
        let published = recorder.reports.count

        proc.zeroAndSendAll()
        let releases = recorder.reports.dropFirst(published)
        XCTAssertEqual(releases.count, 2)
        XCTAssertTrue(releases.allSatisfy { $0.report == .released })
        XCTAssertEqual(Set(releases.map(\.id)), ["a", "b"])
    }

    func testRemoveDropsDevice() {
        let proc = GamepadInputProcessor()
        let recorder = InputRecorder()
        proc.route(recorder.route)
        proc.publish(deviceId: "a", state: .init())
        let removed = proc.feed(for: "a")
        proc.publish(deviceId: "b", state: .init())
        let published = recorder.reports.count

        proc.remove(deviceId: "a")
        proc.zeroAndSendAll()
        XCTAssertEqual(recorder.reports.dropFirst(published).map(\.id), ["b"])
        removed.publish(GamepadReport(buttons: 7))
        XCTAssertFalse(recorder.reports.contains { $0.report.buttons == 7 }, "a removed pad's feed routes nowhere")
    }

    // MARK: - Per-device deadzones

    func testApplyDeadzonesZerosSticksBelowThreshold() {
        let dz = GamepadInputProcessor.Deadzones(stickFlat: 3277, triggerFlat: 13)
        let state = GamepadInputProcessor.DeviceState(
            buttons: 0,
            lt: 0,
            rt: 0,
            lx: 1500,
            ly: -2000,
            rx: 3277,
            ry: -3277
        )
        let out = applyDeadzones(state, dz)
        XCTAssertEqual(out.lx, 0)
        XCTAssertEqual(out.ly, 0)
        XCTAssertEqual(out.rx, 0)
        XCTAssertEqual(out.ry, 0)
    }

    func testApplyDeadzonesPassesSticksAboveThreshold() {
        let dz = GamepadInputProcessor.Deadzones(stickFlat: 3277, triggerFlat: 13)
        let state = GamepadInputProcessor.DeviceState(
            buttons: 0,
            lt: 0,
            rt: 0,
            lx: 3278,
            ly: -3278,
            rx: 32767,
            ry: -32767
        )
        let out = applyDeadzones(state, dz)
        XCTAssertEqual(out.lx, 3278)
        XCTAssertEqual(out.ly, -3278)
        XCTAssertEqual(out.rx, 32767)
        XCTAssertEqual(out.ry, -32767)
    }

    func testApplyDeadzonesZerosTriggersAtOrBelowThreshold() {
        let dz = GamepadInputProcessor.Deadzones(stickFlat: 0, triggerFlat: 13)
        let state = GamepadInputProcessor.DeviceState(
            buttons: 0,
            lt: 5,
            rt: 13,
            lx: 0,
            ly: 0,
            rx: 0,
            ry: 0
        )
        let out = applyDeadzones(state, dz)
        XCTAssertEqual(out.lt, 0)
        XCTAssertEqual(out.rt, 0)
    }

    func testApplyDeadzonesPassesTriggersAboveThreshold() {
        let dz = GamepadInputProcessor.Deadzones(stickFlat: 0, triggerFlat: 13)
        let state = GamepadInputProcessor.DeviceState(
            buttons: 0,
            lt: 14,
            rt: 255,
            lx: 0,
            ly: 0,
            rx: 0,
            ry: 0
        )
        let out = applyDeadzones(state, dz)
        XCTAssertEqual(out.lt, 14)
        XCTAssertEqual(out.rt, 255)
    }

    func testApplyDeadzonesNeverTouchesButtons() {
        let dz = GamepadInputProcessor.Deadzones(stickFlat: 32767, triggerFlat: 255)
        let state = GamepadInputProcessor.DeviceState(
            buttons: 0xABCD,
            lt: 0,
            rt: 0,
            lx: 0,
            ly: 0,
            rx: 0,
            ry: 0
        )
        let out = applyDeadzones(state, dz)
        XCTAssertEqual(out.buttons, 0xABCD)
    }

    func testApplyDeadzonesNeverTouchesTheExtendedButtons() {
        let dz = GamepadInputProcessor.Deadzones(stickFlat: 32767, triggerFlat: 255)
        let state = GamepadInputProcessor.DeviceState(extButtons: 0x1FFF)
        XCTAssertEqual(applyDeadzones(state, dz).extButtons, 0x1FFF)
    }

    func testPublishUsesPerDeviceDeadzones() {
        let proc = GamepadInputProcessor()
        let recorder = InputRecorder()
        proc.route(recorder.route)
        proc.setDeadzones(deviceId: "pad-1", .init(stickFlat: 5000, triggerFlat: 20))
        proc.publish(deviceId: "pad-1", state: .init(buttons: 0, lt: 18, rt: 21, lx: 4999, ly: 5001, rx: 0, ry: 0))
        let sent = recorder.reports.last?.report
        XCTAssertEqual(sent?.lx, 0, "below the flat")
        XCTAssertEqual(sent?.ly, 5001, "above the flat")
        XCTAssertEqual(sent?.lt, 0, "at or below the trigger's flat")
        XCTAssertEqual(sent?.rt, 21, "above the trigger's flat")
    }

    func testPublishAppliesDifferentDeadzonesPerDevice() {
        let proc = GamepadInputProcessor()
        let recorder = InputRecorder()
        proc.route(recorder.route)
        proc.setDeadzones(deviceId: "lax", .init(stickFlat: 0, triggerFlat: 0))
        proc.setDeadzones(deviceId: "strict", .init(stickFlat: 10000, triggerFlat: 0))
        proc.publish(deviceId: "lax", state: .init(lx: 500))
        proc.publish(deviceId: "strict", state: .init(lx: 500))
        let byId = Dictionary(recorder.reports.map { ($0.id, $0.report.lx) }) { _, last in last }
        XCTAssertEqual(byId["lax"], 500)
        XCTAssertEqual(byId["strict"], 0)
    }

    func testDeadzonesSetBeforeAPadsFeedAreItsFromTheFirstReport() {
        let proc = GamepadInputProcessor()
        let recorder = InputRecorder()
        proc.route(recorder.route)
        proc.setDeadzones(deviceId: "late", .init(stickFlat: 5000, triggerFlat: 0))
        proc.feed(for: "late").publish(.init(lx: 100))
        XCTAssertEqual(recorder.reports.last?.report.lx, 0)
    }

    func testRemoveClearsDeadzonesToo() {
        let proc = GamepadInputProcessor()
        let recorder = InputRecorder()
        proc.route(recorder.route)
        proc.setDeadzones(deviceId: "pad", .init(stickFlat: 5000, triggerFlat: 0))
        proc.remove(deviceId: "pad")
        // A fresh publish without re-setting the dead zones passes the small
        // value through rather than zeroing it.
        proc.publish(deviceId: "pad", state: .init(lx: 100))
        XCTAssertEqual(recorder.reports.last?.report.lx, 100)
    }
}
