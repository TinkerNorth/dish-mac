// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import XCTest

/// The capture-to-assignment fold, ported from dish-linux's
/// `test_joystick_remap_assign.cpp`, and the guided walk over it.
final class RemapAssignTests: XCTestCase {

    private let button9 = RawCapture(kind: .button, index: 9)

    func testAFaceButtonIsRoutedToItsRawSource() {
        let remap = withAssignment(JoystickRemap(), .button(.faceA), button9)
        XCTAssertEqual(remap.button(.faceA), 9)
        XCTAssertEqual(remap.button(.faceB), 1, "an untouched target keeps its routing")
    }

    func testEachShoulderSystemAndThumbButtonIsRouted() {
        let targets: [RemapButton] = [.leftShoulder, .rightShoulder, .back, .start, .leftThumb, .rightThumb]
        var remap = JoystickRemap()
        for (offset, which) in targets.enumerated() {
            remap = withAssignment(remap, .button(which), RawCapture(kind: .button, index: offset + 3))
        }
        XCTAssertEqual(targets.map(remap.button), [3, 4, 5, 6, 7, 8])
        XCTAssertEqual(withAssignment(remap, .guide, button9).guide, 9)
    }

    func testAStickAxisIsRoutedAndARightStickEndsTheAdaptiveGuess() {
        let left = withAssignment(JoystickRemap(), .leftStickX, RawCapture(kind: .axis, index: 4))
        XCTAssertEqual(left.leftStickX, 4)
        XCTAssertTrue(left.useAdaptiveRightStick)
        let right = withAssignment(JoystickRemap(), .rightStickY, RawCapture(kind: .axis, index: 2))
        XCTAssertEqual(right.rightStickY, 2)
        XCTAssertFalse(right.useAdaptiveRightStick)
        XCTAssertEqual(withAssignment(JoystickRemap(), .leftStickY, RawCapture(kind: .axis, index: 3)).leftStickY, 3)
        XCTAssertEqual(withAssignment(JoystickRemap(), .rightStickX, RawCapture(kind: .axis, index: 5)).rightStickX, 5)
    }

    func testATriggerTakesItsKindFromTheCapture() {
        let analog = withAssignment(JoystickRemap(), .leftTrigger, RawCapture(kind: .axis, index: 5))
        XCTAssertEqual(analog.leftTrigger, TriggerSource(kind: .axis, index: 5))
        XCTAssertFalse(analog.useAdaptiveTriggers)
        let digital = withAssignment(JoystickRemap(), .rightTrigger, RawCapture(kind: .button, index: 8))
        XCTAssertEqual(digital.rightTrigger, TriggerSource(kind: .button, index: 8))
        XCTAssertFalse(digital.useAdaptiveTriggers)
    }

    func testTheDpadFromTheHatDropsTheDirectionsButtonAndFromAButtonKeepsTheHat() {
        var start = JoystickRemap()
        start.setButton(.dpadUp, 4)
        start.hatIndex = -1
        let viaHat = withAssignment(start, .button(.dpadUp), RawCapture(kind: .hat, index: 0))
        XCTAssertEqual(viaHat.hatIndex, 0)
        XCTAssertEqual(viaHat.button(.dpadUp), -1)
        let viaButton = withAssignment(JoystickRemap(), .button(.dpadDown), RawCapture(kind: .button, index: 11))
        XCTAssertEqual(viaButton.button(.dpadDown), 11)
        XCTAssertEqual(viaButton.hatIndex, 0, "the hat still drives the other directions")
    }

    func testEachInvertFlagTogglesAlone() {
        let offLeft = withInvert(JoystickRemap(), .leftY, false)
        XCTAssertFalse(offLeft.invertLeftY)
        XCTAssertTrue(offLeft.invertRightY)
        let offRight = withInvert(JoystickRemap(), .rightY, false)
        XCTAssertFalse(offRight.invertRightY)
        XCTAssertTrue(offRight.invertLeftY)
        XCTAssertTrue(withInvert(offLeft, .leftY, true).invertLeftY)
    }

    func testTheCaptureGatesTakeADeliberateMoveAndNoRelease() {
        XCTAssertFalse(captureAxisPasses(0))
        XCTAssertFalse(captureAxisPasses(3000))
        XCTAssertFalse(captureAxisPasses(-16000), "the threshold itself is still jitter")
        XCTAssertTrue(captureAxisPasses(20000))
        XCTAssertTrue(captureAxisPasses(-32768))
        XCTAssertTrue(captureButtonPasses())
        XCTAssertFalse(captureHatPasses(0))
        XCTAssertTrue(captureHatPasses(WireButton.dpadUp.bit | WireButton.dpadRight.bit), "a diagonal still passes")
    }

    // MARK: - The walk

    private func walk(at step: Int = 0) -> RemapAssignState {
        var state = RemapAssignState(remap: defaultRemap(order: .western), defaults: defaultRemap(order: .western))
        state.stepIndex = step
        return state
    }

    func testTheWalkAsksForEveryWireControlThenEachStickUp() {
        XCTAssertEqual(remapWalk.count, 19)
        XCTAssertEqual(remapWalk.first, .assign(.button(.faceA)))
        XCTAssertTrue(remapWalk.contains(.assign(.guide)))
        XCTAssertEqual(Array(remapWalk.suffix(4)), [.assign(.leftTrigger), .assign(.rightTrigger), .invert(.leftY), .invert(.rightY)])
    }

    func testACapturedPressIsStoredAndTheWalkMovesOn() {
        let reduction = reduceRemapAssign(walk(), .captured(button9))
        XCTAssertEqual(reduction.next.remap.button(.faceA), 9)
        XCTAssertEqual(reduction.next.stepIndex, 1)
        XCTAssertEqual(reduction.effects, [.store(reduction.next.remap), .listen])
    }

    func testAChangeThatCannotDriveTheStepIsNotTakenAndTheWalkListensOn() {
        let stick = reduceRemapAssign(walk(), .captured(RawCapture(kind: .axis, index: 0, travel: 30000)))
        XCTAssertEqual(stick.next, walk())
        XCTAssertEqual(stick.effects, [.listen])
        let hatForGuide = reduceRemapAssign(walk(at: 8), .captured(RawCapture(kind: .hat, index: 0)))
        XCTAssertEqual(hatForGuide.effects, [.listen], "the hat drives only the d-pad")
        let trigger = reduceRemapAssign(walk(at: 15), .captured(RawCapture(kind: .axis, index: 2, travel: 60000)))
        XCTAssertEqual(trigger.next.remap.leftTrigger, TriggerSource(kind: .axis, index: 2))
    }

    func testSkipLeavesTheControlAndTheLastStepStopsListening() {
        let skipped = reduceRemapAssign(walk(), .skip)
        XCTAssertEqual(skipped.next.stepIndex, 1)
        XCTAssertEqual(skipped.next.remap, walk().remap)
        XCTAssertEqual(skipped.effects, [.listen])
        let last = reduceRemapAssign(walk(at: remapWalk.count - 1), .skip)
        XCTAssertNil(last.next.step)
        XCTAssertEqual(last.effects, [.stopListening])
        XCTAssertEqual(reduceRemapAssign(last.next, .captured(button9)).effects, [.stopListening], "a done walk takes nothing")
        XCTAssertEqual(reduceRemapAssign(last.next, .skip).next.stepIndex, remapWalk.count)
    }

    func testResetDropsTheStoredRemapAndRestartKeepsIt() {
        var assigned = reduceRemapAssign(walk(), .captured(button9)).next
        assigned.stepIndex = 5
        let reset = reduceRemapAssign(assigned, .reset)
        XCTAssertEqual(reset.next.remap, assigned.defaults)
        XCTAssertEqual(reset.next.stepIndex, 0)
        XCTAssertEqual(reset.effects, [.clearStored, .listen])
        let restart = reduceRemapAssign(assigned, .restart)
        XCTAssertEqual(restart.next.remap.button(.faceA), 9)
        XCTAssertEqual(restart.next.stepIndex, 0)
        XCTAssertEqual(restart.effects, [.listen])
    }

    /// HID's Y is down-positive: a stick pushed up travels negative, which
    /// is the inverted reading the wire wants.
    func testAStickPushedUpSetsItsYDirectionFromTheSignOfItsTravel() {
        let leftY = remapWalk.count - 2
        let upNegative = reduceRemapAssign(walk(at: leftY), .captured(RawCapture(kind: .axis, index: 1, travel: -30000)))
        XCTAssertTrue(upNegative.next.remap.invertLeftY)
        let upPositive = reduceRemapAssign(walk(at: leftY), .captured(RawCapture(kind: .axis, index: 1, travel: 30000)))
        XCTAssertFalse(upPositive.next.remap.invertLeftY)
        let sideways = reduceRemapAssign(walk(at: leftY), .captured(RawCapture(kind: .axis, index: 0, travel: -30000)))
        XCTAssertEqual(sideways.effects, [.listen], "a push that strays onto X is not the stick's Y")
        let rightY = reduceRemapAssign(walk(at: leftY + 1), .captured(RawCapture(kind: .axis, index: 4, travel: 30000)))
        XCTAssertFalse(rightY.next.remap.invertRightY)
        XCTAssertEqual(rightY.effects.last, .stopListening)
    }
}
