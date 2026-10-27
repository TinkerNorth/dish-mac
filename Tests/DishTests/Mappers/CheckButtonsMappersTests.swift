// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import DishEngine
import XCTest
@testable import Dish

/// "Check the buttons": the page waits for the engine, says why a pad has
/// no walk, asks for one control at a time with the whole table under the
/// prompt, and offers Check again once every control is checked.
final class CheckButtonsMappersTests: XCTestCase {

    private func facts(_ phase: ButtonCheckPhase, slotId: String = "pad") -> ShellFacts {
        var facts = ShellFacts()
        facts.buttonCheck = ButtonCheckFacts(slotId: slotId, name: "Generic Pad", phase: phase)
        return facts
    }

    private func walk(at step: Int = 0, _ remap: JoystickRemap = defaultRemap(order: .western)) -> RemapAssignState {
        var state = RemapAssignState(remap: remap, defaults: defaultRemap(order: .western))
        state.stepIndex = step
        return state
    }

    private func walking(_ state: CheckButtonsPageState) throws -> CheckButtonsWalkState {
        guard case let .walking(walk) = state.content else { return try XCTUnwrap(nil, "not walking: \(state.content)") }
        return walk
    }

    func testThePageWaitsUntilTheEngineAnswersForItsPad() {
        XCTAssertEqual(checkButtonsPageState(slotId: "pad", facts: ShellFacts()).content, .waiting)
        XCTAssertEqual(
            checkButtonsPageState(slotId: "pad", facts: facts(.missing, slotId: "other")).content,
            .waiting,
            "another pad's walk"
        )
    }

    func testAPadThatIsGoneOrCannotBeRemappedSaysSo() {
        XCTAssertEqual(
            checkButtonsPageState(slotId: "pad", facts: facts(.missing)).content,
            .missing(title: "No controllers connected", body: "Connect the controller to check its buttons.")
        )
        XCTAssertEqual(
            checkButtonsPageState(slotId: "pad", facts: facts(.notRemappable)).content,
            .notRemappable(title: "Not remappable", body: "This controller uses its built-in mapping and can’t be remapped here.")
        )
    }

    func testTheWalkAsksForTheControlOnScreenWithTheTableLit() throws {
        let state = try walking(checkButtonsPageState(slotId: "pad", facts: facts(.walking(walk()))))
        XCTAssertEqual(state.name, "Generic Pad")
        XCTAssertEqual(state.progress, "Step 1 of 19")
        XCTAssertEqual(state.prompt, "Press the button you want as A")
        XCTAssertEqual(state.skip, "Skip")
        XCTAssertNil(state.checkAgain)
        XCTAssertEqual(state.reset, "Reset to defaults")
        XCTAssertEqual(state.footnote, "Stored for this controller model — applies on the next report, no re-attach.")
        XCTAssertEqual(state.rows.count, 19)
        XCTAssertEqual(state.rows.first, RemapRowState(id: 0, label: "A", value: "Button 0", ink: DishTheme.primary))
        XCTAssertEqual(state.rows[1].ink, DishTheme.onSurface)
        XCTAssertEqual(state.rows.map(\.label).suffix(4), ["Left trigger", "Right trigger", "Invert left stick Y", "Invert right stick Y"])
    }

    func testEachKindOfStepHasItsPrompt() {
        XCTAssertEqual(remapPrompt(.assign(.guide)), "Press the button you want as Guide")
        XCTAssertEqual(remapPrompt(.assign(.button(.dpadUp))), "Press the button you want as D-pad up")
        XCTAssertEqual(remapPrompt(.assign(.rightTrigger)), "Pull the trigger you want as Right trigger")
        XCTAssertEqual(remapPrompt(.invert(.leftY)), "Push the left stick up")
        XCTAssertEqual(remapPrompt(.invert(.rightY)), "Push the right stick up")
        XCTAssertEqual(remapTargetLabel(.leftStickX), "Left stick")
        XCTAssertEqual(remapTargetLabel(.rightStickY), "Right stick")
    }

    func testEverySourceReadsInTheDesktopsWords() {
        var remap = defaultRemap(order: .western)
        XCTAssertEqual(remapTargetValue(.button(.dpadUp), remap), "Hat 0", "a direction with no button reads the hat")
        remap.hatIndex = -1
        XCTAssertEqual(remapTargetValue(.button(.dpadUp), remap), "Unassigned")
        remap.setButton(.dpadUp, 12)
        XCTAssertEqual(remapTargetValue(.button(.dpadUp), remap), "Button 12", "its own button wins")
        XCTAssertEqual(remapTargetValue(.guide, remap), "Button 10")
        XCTAssertEqual(remapTargetValue(.leftTrigger, remap), "Axis 2 · analog")
        remap.rightTrigger = TriggerSource(kind: .button, index: 7)
        XCTAssertEqual(remapTargetValue(.rightTrigger, remap), "Button 7 · digital")
        remap.leftTrigger = TriggerSource(kind: .axis, index: -1)
        XCTAssertEqual(remapTargetValue(.leftTrigger, remap), "Unassigned")
        XCTAssertEqual(remapTargetValue(.leftStickY, remap), "Axis 1 · analog")
        remap.rightStickX = -1
        XCTAssertEqual(remapTargetValue(.rightStickX, remap), "Unassigned")
        remap.invertRightY = false
        XCTAssertEqual(remapStepValue(.invert(.leftY), remap), "On")
        XCTAssertEqual(remapStepValue(.invert(.rightY), remap), "Off")
    }

    func testADoneWalkOffersToCheckAgainInsteadOfSkip() throws {
        let state = try walking(checkButtonsPageState(slotId: "pad", facts: facts(.walking(walk(at: remapWalk.count)))))
        XCTAssertNil(state.progress)
        XCTAssertNil(state.skip)
        XCTAssertEqual(state.checkAgain, "Check again")
        XCTAssertEqual(state.prompt, "Every control is checked.")
        XCTAssertTrue(state.rows.allSatisfy { $0.ink == DishTheme.onSurface }, "nothing is asked for")
    }
}
