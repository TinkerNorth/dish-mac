// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import GameController
import XCTest
@testable import DishEngine

/// The bridge over GameController's own snapshot pad, which holds values the
/// test sets and attaches like a real one: the sample is taken in the
/// framework's orientation, a connect turns background input on and hands
/// the pad the input queue, and the handlers run there, off the main thread.
@MainActor
final class GameControllerInputTests: XCTestCase {

    override func setUp() {
        super.setUp()
        GCController.shouldMonitorBackgroundEvents = false
    }

    private func snapshotPad() throws -> (GCController, GCExtendedGamepad) {
        let controller = GCController.withExtendedGamepad()
        return try (controller, XCTUnwrap(controller.extendedGamepad))
    }

    private func spinUntil(_ predicate: () -> Bool, message: String) {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline, !predicate() {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(predicate(), message)
    }

    func testAStickPushedUpIsSampledUpAndTheHomeButtonIsGuide() throws {
        let (_, pad) = try snapshotPad()
        pad.leftThumbstick.setValueForXAxis(-1, yAxis: 1)
        pad.rightThumbstick.setValueForXAxis(1, yAxis: -1)
        pad.buttonHome?.setValue(1)
        pad.buttonA.setValue(1)
        pad.leftTrigger.setValue(1)
        let sample = GameControllerInput.padSample(pad)
        let report = wireReport(sample)
        XCTAssertEqual(sample.pressed, [.guide, .faceA], "the sample's word holds exactly the held buttons")
        XCTAssertEqual(report.ly, 32767, "up on the pad is up on the wire")
        XCTAssertEqual(report.ry, -32767)
        XCTAssertEqual(report.lx, -32767)
        XCTAssertEqual(report.rx, 32767)
        XCTAssertEqual(report.lt, 255)
        XCTAssertEqual(report.buttons, WireButton.guide.bit | WireButton.faceA.bit)
    }

    func testTheEngineButtonBitsAreTheWireTable() {
        typealias Btn = GamepadInputProcessor.Buttons
        let engine: [(UInt16, WireButton)] = [
            (Btn.dpadUp, .dpadUp), (Btn.dpadDown, .dpadDown), (Btn.dpadLeft, .dpadLeft), (Btn.dpadRight, .dpadRight),
            (Btn.start, .start), (Btn.back, .back), (Btn.leftThumb, .leftThumb), (Btn.rightThumb, .rightThumb),
            (Btn.leftShoulder, .leftShoulder), (Btn.rightShoulder, .rightShoulder), (Btn.guide, .guide),
            (Btn.faceA, .faceA), (Btn.faceB, .faceB), (Btn.faceX, .faceX), (Btn.faceY, .faceY)
        ]
        for (bit, button) in engine {
            XCTAssertEqual(bit, button.bit, "\(button)")
        }
    }

    func testALaunchSweepWithAPadTurnsBackgroundInputOnAndAnEmptyOneLeavesItAlone() throws {
        let empty = GameControllerInput(connected: [])
        XCTAssertFalse(empty.monitorsBackgroundEvents, "no pad, no connect, nothing set")
        let (controller, _) = try snapshotPad()
        let input = GameControllerInput(connected: [controller])
        XCTAssertTrue(input.monitorsBackgroundEvents)
        XCTAssertEqual(input.slots.count, 1)
    }

    func testAConnectTurnsBackgroundInputOnAndHandsThePadTheInputQueue() throws {
        let input = GameControllerInput(connected: [])
        let (controller, pad) = try snapshotPad()
        NotificationCenter.default.post(name: .GCControllerDidConnect, object: controller)
        spinUntil({ !input.slots.isEmpty }, message: "the connect attaches the pad")
        XCTAssertTrue(GCController.shouldMonitorBackgroundEvents)
        XCTAssertTrue(controller.handlerQueue === input.inputQueue)
        XCTAssertNotNil(pad.valueChangedHandler)
        NotificationCenter.default.post(name: .GCControllerDidDisconnect, object: controller)
        spinUntil({ input.slots.isEmpty }, message: "the disconnect detaches it")
    }

    func testTheReportHandlerPublishesOnTheInputQueueOffTheMainThread() throws {
        let (controller, pad) = try snapshotPad()
        let input = GameControllerInput(connected: [controller])
        let published = expectation(description: "a report left the processor")
        let seen = LockedBox<(report: GamepadReport, onMain: Bool)?>(nil)
        input.processor.reportSender = { _, report in
            seen.set((report, Thread.isMainThread))
            published.fulfill()
        }
        pad.leftThumbstick.setValueForXAxis(0, yAxis: 1)
        let call = FrameworkCall(pad: pad)
        XCTAssertNotNil(pad.valueChangedHandler)
        input.inputQueue.async { call.fire() }
        wait(for: [published], timeout: 2)
        XCTAssertEqual(seen.get()?.report.ly, 32767)
        XCTAssertEqual(seen.get()?.onMain, false, "the hot path never waits on the main thread")
    }

    // MARK: - A pad's name read back from its id

    func testAPadThatIsAwayIsNamedAsTheSlotListNamedIt() throws {
        let (controller, _) = try snapshotPad()
        let input = GameControllerInput()
        let slotId = input.slotId(for: controller)
        let listed = controller.vendorName ?? controller.productCategory
        XCTAssertEqual(padName(fromSlotId: slotId), listed, "the id carries what the slot list showed")
    }

    func testTheNameInASlotIdIsItsVendorOrItsCategory() {
        XCTAssertEqual(padName(fromSlotId: "gc:Xbox Wireless Controller:Xbox One"), "Xbox Wireless Controller")
        XCTAssertEqual(padName(fromSlotId: "gc:DualSense Wireless Controller:DualSense#1"), "DualSense Wireless Controller")
        XCTAssertEqual(
            padName(fromSlotId: "gc:unknown:Nintendo Switch Online N64#2"),
            "Nintendo Switch Online N64",
            "no vendor: the category"
        )
        XCTAssertEqual(padName(fromSlotId: "pad"), "pad", "an id of another shape is its own name")
    }
}

/// Calls a handler the way the framework does, from the queue the pad was
/// handed. The framework's objects are not `Sendable`; this test owns them
/// and touches them on one queue at a time.
private struct FrameworkCall: @unchecked Sendable {
    let pad: GCExtendedGamepad

    func fire() {
        pad.valueChangedHandler?(pad, pad.leftThumbstick)
    }
}
