// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import XCTest
@testable import DishEngine

/// The inspector over the real processor: it taps one slot's reports as the
/// host sees them and as the pad sent them, reads motion and touch in human
/// units, measures the rate, and runs a stick test on its own clock.
@MainActor
final class InputInspectorTests: XCTestCase {

    private var clock: Int64 = 1000
    private var processor: GamepadInputProcessor!
    private var inspector: InputInspector!

    override func setUp() {
        super.setUp()
        processor = GamepadInputProcessor()
        inspector = InputInspector(processor: processor, now: { [unowned self] in self.clock }, pollMs: 10000)
    }

    override func tearDown() {
        inspector.disarm()
        super.tearDown()
    }

    private func report(buttons: UInt16 = 0, lx: Int16 = 0, ly: Int16 = 0, rx: Int16 = 0, ry: Int16 = 0, lt: UInt8 = 0) -> GamepadReport {
        GamepadReport(buttons: buttons, lt: lt, rt: 0, lx: lx, ly: ly, rx: rx, ry: ry)
    }

    func testArmingTapsOneSlotAndTheTickReadsTheHostsViewAndTheRawSticks() {
        processor.setDeadzones(deviceId: "pad", .init(stickFlat: 3000, triggerFlat: 0))
        inspector.arm("pad")
        XCTAssertEqual(inspector.state, InputInspection(slotId: "pad"))
        processor.publish(deviceId: "other", state: report(buttons: 0xFFFF))
        processor.publish(deviceId: "pad", state: report(buttons: 0x1001, lx: 2000, rx: 16384, lt: 255))
        clock += 500
        inspector.tick()
        let snapshot = inspector.state.snapshot
        XCTAssertEqual(snapshot?.buttons, 0x1001, "the other pad's word never got in")
        XCTAssertEqual(snapshot?.leftStick, .centre, "inside the dead zone, the host sees centre")
        XCTAssertEqual(snapshot?.rawLeft.x ?? 0, 2000 / 32768, accuracy: 0.0001, "the pad's own word stays raw")
        XCTAssertEqual(snapshot?.rightStick.x, 0.5)
        XCTAssertEqual(snapshot?.leftTrigger, 1)
        XCTAssertNil(snapshot?.motion)
        XCTAssertNil(snapshot?.touch)
        XCTAssertEqual(inspector.state.reportsHz, 0, "the first poll anchors the rate")
        for _ in 0 ..< 10 {
            processor.publish(deviceId: "pad", state: report())
        }
        clock += 500
        inspector.tick()
        XCTAssertEqual(inspector.state.reportsHz, 20, "ten reports in half a second")
    }

    func testMotionAndTouchReadInHumanUnits() {
        inspector.arm("pad")
        processor.publish(deviceId: "pad", state: report())
        processor.publishMotion(
            deviceId: "pad",
            sample: MotionSample(gyroX: 32767, gyroY: 0, gyroZ: -16384, accelX: 0, accelY: 32767, accelZ: 0)
        )
        let finger = TouchpadFinger(active: true, id: 1, x: 0, y: 32767)
        let lifted = TouchpadFinger(active: false, id: 0, x: 0, y: 0)
        processor.publishTouchpad(deviceId: "pad", sample: TouchpadSample(finger0: finger, finger1: lifted, buttonPressed: true))
        inspector.tick()
        let motion = inspector.state.snapshot?.motion
        XCTAssertEqual(motion?.gyroX, 2000)
        XCTAssertEqual(motion?.gyroZ ?? 0, -1000, accuracy: 0.1)
        XCTAssertEqual(motion?.accelY, 4)
        let touch = inspector.state.snapshot?.touch
        XCTAssertEqual(touch?.finger1?.x ?? -1, 0.5, accuracy: 0.0001)
        XCTAssertEqual(touch?.finger1?.y, 1)
        XCTAssertNil(touch?.finger2, "a lifted finger is no finger")
        XCTAssertEqual(touch?.click, true)
    }

    func testAStickTestRunsOnTheInspectorsClockAndReadsTheRawSticks() {
        processor.setDeadzones(deviceId: "pad", .init(stickFlat: 5000, triggerFlat: 0))
        inspector.arm("pad")
        processor.publish(deviceId: "pad", state: report(lx: 3277))
        inspector.startStickTest(.drift)
        XCTAssertEqual(inspector.state.bench.phase, .running)
        XCTAssertEqual(inspector.state.secondsLeft, 4, "whole seconds left plus one, so it never reads zero while running")
        clock += 1000
        inspector.tick()
        XCTAssertEqual(inspector.state.secondsLeft, 3)
        clock += 1000
        inspector.tick()
        XCTAssertEqual(inspector.state.secondsLeft, 2)
        clock += 1000
        inspector.tick()
        XCTAssertEqual(inspector.state.bench.phase, .done)
        XCTAssertEqual(inspector.state.secondsLeft, 0)
        let result = inspector.state.bench.result
        XCTAssertEqual(result?.samples, 4, "one sample per poll, the start included")
        XCTAssertEqual(result?.driftLeft ?? 0, 0.1, accuracy: 0.001, "the dead zone zeroed it for the host, not for the test")
        XCTAssertEqual(result?.suggestedDeadzone ?? 0, 0.15, accuracy: 0.0001)
    }

    func testDisarmingClearsTheStateAndTheTapsAndArmingAnotherSlotDropsTheTest() {
        inspector.arm("pad")
        inspector.startStickTest(.range)
        inspector.arm("second")
        XCTAssertEqual(inspector.state, InputInspection(slotId: "second"), "a new slot starts clean")
        inspector.disarm()
        XCTAssertEqual(inspector.state, .disarmed)
        XCTAssertNil(processor.reportTap)
        XCTAssertNil(processor.motionTap)
        XCTAssertNil(processor.touchpadTap)
        inspector.startStickTest(.drift)
        inspector.tick()
        XCTAssertEqual(inspector.state, .disarmed, "nothing is armed, nothing runs")
    }
}
