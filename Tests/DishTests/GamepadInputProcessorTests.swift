// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import XCTest
@testable import Dish

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
        XCTAssertEqual(Btn.faceA, 0x1000)
        XCTAssertEqual(Btn.faceB, 0x2000)
        XCTAssertEqual(Btn.faceX, 0x4000)
        XCTAssertEqual(Btn.faceY, 0x8000)
    }

    // MARK: - Publish routes to ReportSender

    private struct CapturedReport {
        let id: String
        let buttons: UInt16
        let lt: UInt8
        let rt: UInt8
        let lx: Int16
        let ly: Int16
        let rx: Int16
        let ry: Int16
    }

    func testPublishForwardsStateToReportSender() {
        let proc = GamepadInputProcessor()
        var captured: CapturedReport?
        proc.reportSender = { id, buttons, lt, rt, lx, ly, rx, ry in
            captured = CapturedReport(
                id: id,
                buttons: buttons,
                lt: lt,
                rt: rt,
                lx: lx,
                ly: ly,
                rx: rx,
                ry: ry
            )
        }
        let state = GamepadInputProcessor.DeviceState(
            wButtons: 0x1234,
            lt: 10,
            rt: 20,
            lx: 100,
            ly: -200,
            rx: 300,
            ry: -400
        )
        proc.publish(deviceId: "pad-1", state: state)

        XCTAssertEqual(captured?.id, "pad-1")
        XCTAssertEqual(captured?.buttons, 0x1234)
        XCTAssertEqual(captured?.lt, 10)
        XCTAssertEqual(captured?.rt, 20)
        XCTAssertEqual(captured?.lx, 100)
        XCTAssertEqual(captured?.ly, -200)
        XCTAssertEqual(captured?.rx, 300)
        XCTAssertEqual(captured?.ry, -400)
    }

    // MARK: - zeroAndSendAll fans a release-all report to every known device

    func testZeroAndSendAllEmitsReleasedReportPerDevice() {
        let proc = GamepadInputProcessor()
        var emitted: [CapturedReport] = []
        proc.reportSender = { id, buttons, lt, rt, lx, ly, rx, ry in
            emitted.append(CapturedReport(
                id: id,
                buttons: buttons,
                lt: lt,
                rt: rt,
                lx: lx,
                ly: ly,
                rx: rx,
                ry: ry
            ))
        }
        proc.publish(deviceId: "a", state: .init(
            wButtons: 1,
            lt: 5,
            rt: 6,
            lx: 7,
            ly: 8,
            rx: 9,
            ry: 10
        ))
        proc.publish(deviceId: "b", state: .init(
            wButtons: 2,
            lt: 11,
            rt: 12,
            lx: 13,
            ly: 14,
            rx: 15,
            ry: 16
        ))
        emitted.removeAll()

        proc.zeroAndSendAll()
        XCTAssertEqual(emitted.count, 2)
        for entry in emitted {
            XCTAssertEqual(entry.buttons, 0)
            XCTAssertEqual(entry.lt, 0)
            XCTAssertEqual(entry.rt, 0)
            XCTAssertEqual(entry.lx, 0)
            XCTAssertEqual(entry.ly, 0)
            XCTAssertEqual(entry.rx, 0)
            XCTAssertEqual(entry.ry, 0)
        }
        XCTAssertEqual(Set(emitted.map(\.id)), ["a", "b"])
    }

    func testRemoveDropsDevice() {
        let proc = GamepadInputProcessor()
        var emitted: [String] = []
        proc.reportSender = { id, _, _, _, _, _, _, _ in emitted.append(id) }
        proc.publish(deviceId: "a", state: .init())
        proc.publish(deviceId: "b", state: .init())
        emitted.removeAll()

        proc.remove(deviceId: "a")
        proc.zeroAndSendAll()
        XCTAssertEqual(emitted, ["b"])
    }

    // MARK: - Per-device deadzones

    func testApplyDeadzonesZerosSticksBelowThreshold() {
        let dz = GamepadInputProcessor.Deadzones(stickFlat: 3277, triggerFlat: 13)
        let state = GamepadInputProcessor.DeviceState(
            wButtons: 0,
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
            wButtons: 0,
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
            wButtons: 0,
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
            wButtons: 0,
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
            wButtons: 0xABCD,
            lt: 0,
            rt: 0,
            lx: 0,
            ly: 0,
            rx: 0,
            ry: 0
        )
        let out = applyDeadzones(state, dz)
        XCTAssertEqual(out.wButtons, 0xABCD)
    }

    func testPublishUsesPerDeviceDeadzones() {
        let proc = GamepadInputProcessor()
        var captured: (Int16, Int16, UInt8, UInt8)?
        proc.reportSender = { _, _, lt, rt, lx, ly, _, _ in
            captured = (lx, ly, lt, rt)
        }
        proc.setDeadzones(
            deviceId: "pad-1",
            .init(stickFlat: 5000, triggerFlat: 20)
        )
        proc.publish(
            deviceId: "pad-1",
            state: .init(wButtons: 0, lt: 18, rt: 21, lx: 4999, ly: 5001, rx: 0, ry: 0)
        )
        XCTAssertEqual(captured?.0, 0)      // lx below flat → zeroed
        XCTAssertEqual(captured?.1, 5001)   // ly above flat → passed
        XCTAssertEqual(captured?.2, 0)      // lt at/below flat → zeroed
        XCTAssertEqual(captured?.3, 21)     // rt above flat → passed
    }

    func testPublishAppliesDifferentDeadzonesPerDevice() {
        let proc = GamepadInputProcessor()
        var byId: [String: Int16] = [:]
        proc.reportSender = { id, _, _, _, lx, _, _, _ in byId[id] = lx }
        proc.setDeadzones(deviceId: "lax", .init(stickFlat: 0, triggerFlat: 0))
        proc.setDeadzones(deviceId: "strict", .init(stickFlat: 10000, triggerFlat: 0))
        proc.publish(deviceId: "lax", state: .init(lx: 500))
        proc.publish(deviceId: "strict", state: .init(lx: 500))
        XCTAssertEqual(byId["lax"], 500)
        XCTAssertEqual(byId["strict"], 0)
    }

    func testRemoveClearsDeadzonesToo() {
        let proc = GamepadInputProcessor()
        var lastLx: Int16 = -1
        proc.reportSender = { _, _, _, _, lx, _, _, _ in lastLx = lx }
        proc.setDeadzones(deviceId: "pad", .init(stickFlat: 5000, triggerFlat: 0))
        proc.remove(deviceId: "pad")
        // Fresh publish without re-setting deadzones should now pass through
        // the small value rather than zeroing it.
        proc.publish(deviceId: "pad", state: .init(lx: 100))
        XCTAssertEqual(lastLx, 100)
    }
}
