// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import XCTest
@testable import DishCore

/// The Configure binding page's draft: every edit lands in the draft and
/// nothing else, a new destination starts its type over, the draft is dirty
/// exactly while it differs from what the page opened with, and it can be
/// applied once it names a destination.
final class BindingDraftTests: XCTestCase {

    private let bound = BindingChoice(connectionId: "den", emulatedType: 5)
    private var draft: BindingDraft {
        BindingDraft(slotId: "pad", original: bound)
    }

    func testAFreshDraftHoldsWhatThePageOpenedWithAndIsClean() {
        XCTAssertEqual(draft.current, bound)
        XCTAssertFalse(isDirty(draft))
    }

    func testChoosingAnotherDestinationStartsTheTypeOverAtAuto() {
        let next = reduce(draft, .chooseDestination("loft"))
        XCTAssertEqual(next.current.connectionId, "loft")
        XCTAssertNil(next.current.emulatedType, "another host is another catalog")
        XCTAssertTrue(isDirty(next))
    }

    func testChoosingTheSameDestinationKeepsTheType() {
        let next = reduce(draft, .chooseDestination("den"))
        XCTAssertEqual(next.current.emulatedType, 5)
        XCTAssertFalse(isDirty(next))
    }

    func testChoosingATypeIsDirtyAndAutoIsNil() {
        let picked = reduce(draft, .chooseType(7))
        XCTAssertEqual(picked.current.emulatedType, 7)
        XCTAssertTrue(isDirty(picked))
        XCTAssertNil(reduce(picked, .chooseType(nil)).current.emulatedType)
    }

    func testEachSwitchLandsInTheDraftAlone() {
        let edited = [
            BindingDraftEvent.setMotion(false), .setRumble(false), .setTouchpad(.mouse), .setMic(true), .setSpeaker(false)
        ].reduce(draft) { reduce($0, $1) }
        XCTAssertFalse(edited.current.motion)
        XCTAssertFalse(edited.current.rumble)
        XCTAssertEqual(edited.current.touchpad, .mouse)
        XCTAssertTrue(edited.current.mic)
        XCTAssertFalse(edited.current.speaker)
        XCTAssertEqual(edited.original, bound, "the opened state stays the baseline")
    }

    func testAnEditUndoneByHandIsCleanAgain() {
        let undone = reduce(reduce(draft, .setRumble(false)), .setRumble(true))
        XCTAssertFalse(isDirty(undone))
    }

    func testResetReturnsToWhatThePageOpenedWith() {
        let reset = reduce(reduce(draft, .chooseDestination("loft")), .reset)
        XCTAssertEqual(reset.current, bound)
        XCTAssertFalse(isDirty(reset))
    }

    func testAppliedMakesTheCurrentChoiceTheNewBaseline() {
        let applied = reduce(reduce(draft, .setMic(true)), .applied)
        XCTAssertEqual(applied.original, applied.current)
        XCTAssertFalse(isDirty(applied))
    }

    func testADraftWithoutADestinationCannotApply() {
        let unbound = BindingDraft(slotId: "pad", original: BindingChoice())
        XCTAssertFalse(canApply(unbound))
        XCTAssertTrue(canApply(reduce(unbound, .chooseDestination("den"))))
    }

    func testABoundDraftCanApplyUnchanged() {
        XCTAssertTrue(canApply(draft), "re-applying sends the binding again")
    }

    func testAnUntouchedChoiceHasTheFleetDefaults() {
        let fresh = BindingChoice()
        XCTAssertNil(fresh.connectionId)
        XCTAssertNil(fresh.emulatedType)
        XCTAssertTrue(fresh.motion)
        XCTAssertTrue(fresh.rumble)
        XCTAssertEqual(fresh.touchpad, .pad)
        XCTAssertFalse(fresh.mic)
        XCTAssertTrue(fresh.speaker)
    }
}
