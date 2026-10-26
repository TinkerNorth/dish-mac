// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import XCTest
@testable import DishCore

/// The setup wizard as data (the desktops' SetupWizardPage): six questions
/// in three stages, the Moonlight-only Session step stepped over for a
/// satellite both ways, nothing sent until Review's one apply, the leave
/// guard past the first page, and the two blockers that stop the walk when
/// the pad or the host goes away.
final class SetupWizardMachineTests: XCTestCase {

    private let padDraft = BindingDraft(slotId: "pad", original: BindingChoice())
    private var boundToDen: BindingDraft {
        BindingDraft(slotId: "pad", original: BindingChoice(connectionId: "den"))
    }

    private func run(_ state: SetupWizardState, _ events: [SetupWizardEvent]) -> SetupWizardState {
        events.reduce(state) { reduceSetup($0, $1).state }
    }

    /// A wizard on `step` with the pad picked and a host of `kind` chosen.
    private func walked(to step: SetupStep, kind: SetupHostKind = .satellite) -> SetupWizardState {
        let chosen = run(SetupWizardState(), [.pickPad(padDraft, hostKind: nil), .next, .pickDestination("den", kind)])
        var state = chosen
        while state.step != step {
            state = reduceSetup(state, .next).state
        }
        return state
    }

    // MARK: - Opening

    func testAFreshWizardOpensOnInputWithNothingAnswered() {
        let state = SetupWizardState()
        XCTAssertEqual(state.step, .input)
        XCTAssertNil(state.draft)
        XCTAssertNil(state.blocker)
        XCTAssertFalse(setupLeaveGuarded(state), "a pristine first page loses nothing")
    }

    func testASeededWizardOpensOnDestinationWithThePadPreAnswered() {
        let state = SetupWizardState(seed: padDraft, hostKind: nil)
        XCTAssertEqual(state.step, .destination)
        XCTAssertEqual(state.draft, padDraft)
        XCTAssertTrue(setupLeaveGuarded(state), "past the first page the guard holds")
    }

    // MARK: - Input

    func testNextWaitsForAPad() {
        let step = reduceSetup(SetupWizardState(), .next)
        XCTAssertEqual(step.state.step, .input)
        XCTAssertEqual(step.effects, [])
        XCTAssertFalse(setupCanAdvance(SetupWizardState()))
    }

    func testPickingAPadAnswersInputAndNextLooksForHosts() {
        let picked = reduceSetup(SetupWizardState(), .pickPad(padDraft, hostKind: nil)).state
        XCTAssertEqual(picked.draft, padDraft)
        XCTAssertTrue(setupCanAdvance(picked))
        let next = reduceSetup(picked, .next)
        XCTAssertEqual(next.state.step, .destination)
        XCTAssertEqual(next.effects, [.scan], "entering Destination scans")
    }

    func testPickingAnotherPadStartsItsDraftOverAndTheSamePadKeepsTheAnswers() {
        let edited = run(SetupWizardState(), [.pickPad(padDraft, hostKind: nil), .edit(.setRumble(false))])
        let same = reduceSetup(edited, .pickPad(padDraft, hostKind: nil)).state
        XCTAssertFalse(same.draft?.current.rumble ?? true, "the same pad keeps what was answered")
        let other = BindingDraft(slotId: "other", original: BindingChoice())
        XCTAssertEqual(reduceSetup(edited, .pickPad(other, hostKind: nil)).state.draft, other)
    }

    func testAPadAlreadyBoundBringsItsHostAndKind() {
        let state = reduceSetup(SetupWizardState(), .pickPad(boundToDen, hostKind: .moonlight)).state
        XCTAssertEqual(state.hostKind, .moonlight)
        XCTAssertEqual(state.draft?.current.connectionId, "den")
    }

    // MARK: - Destination

    func testNextWaitsForADestination() {
        let state = run(SetupWizardState(), [.pickPad(padDraft, hostKind: nil), .next])
        XCTAssertFalse(setupCanAdvance(state))
        XCTAssertEqual(reduceSetup(state, .next).state.step, .destination)
    }

    func testPickingADestinationLandsInTheDraftWithItsKind() {
        let state = run(SetupWizardState(), [.pickPad(padDraft, hostKind: nil), .next, .pickDestination("den", .satellite)])
        XCTAssertEqual(state.draft?.current.connectionId, "den")
        XCTAssertEqual(state.hostKind, .satellite)
        XCTAssertTrue(setupCanAdvance(state))
        XCTAssertEqual(reduceSetup(state, .next).state.step, .type)
    }

    func testADestinationBeforeAPadChangesNothing() {
        XCTAssertEqual(reduceSetup(SetupWizardState(), .pickDestination("den", .satellite)).state, SetupWizardState())
        XCTAssertEqual(reduceSetup(SetupWizardState(), .edit(.setMotion(false))).state, SetupWizardState())
    }

    // MARK: - The binding stage

    func testASatelliteStepsOverSessionBothWays() {
        let type = walked(to: .type)
        XCTAssertEqual(reduceSetup(type, .next).state.step, .feel)
        let feel = walked(to: .feel)
        XCTAssertEqual(reduceSetup(feel, .back).state.step, .type)
    }

    func testAMoonlightHostAsksForTheSession() {
        let type = walked(to: .type, kind: .moonlight)
        XCTAssertEqual(reduceSetup(type, .next).state.step, .session)
        let session = reduceSetup(type, .next).state
        XCTAssertEqual(reduceSetup(session, .next).state.step, .feel)
        let feel = walked(to: .feel, kind: .moonlight)
        XCTAssertEqual(reduceSetup(feel, .back).state.step, .session)
    }

    func testFeelLeadsToReviewAndBackWalksEveryStepToInput() {
        let review = reduceSetup(walked(to: .feel), .next).state
        XCTAssertEqual(review.step, .review)
        let steps = (0 ..< 5).reduce(into: [review]) { all, _ in all.append(reduceSetup(all[all.count - 1], .back).state) }
        XCTAssertEqual(steps.map(\.step), [.review, .feel, .type, .destination, .input, .input], "back stops at the first page")
    }

    func testEditsLandInTheDraftOnly() {
        let feel = walked(to: .feel)
        let edited = run(feel, [.edit(.setMotion(false)), .edit(.chooseType(7))])
        XCTAssertFalse(edited.draft?.current.motion ?? true)
        XCTAssertEqual(edited.draft?.current.emulatedType, 7)
        XCTAssertEqual(edited.step, .feel)
    }

    func testReviewsNextIsTheOneApply() {
        let review = walked(to: .review)
        let step = reduceSetup(review, .next)
        XCTAssertEqual(step.effects, [.apply(review.draft ?? padDraft)])
        XCTAssertEqual(step.state.step, .review, "the wizard stays until the apply lands")
    }

    func testNothingIsAppliedBeforeReview() {
        let picked = reduceSetup(SetupWizardState(), .pickPad(padDraft, hostKind: nil)).state
        let before = [picked] + [SetupStep.destination, .type, .feel].map { walked(to: $0) }
        let effects = before.flatMap { reduceSetup($0, .next).effects }
        XCTAssertEqual(effects, [.scan], "only Destination's scan before Review")
    }

    func testTheStagesGroupTheSteps() {
        XCTAssertEqual(SetupStep.allCases.map(setupStage), [.input, .destination, .binding, .binding, .binding, .binding])
    }

    func testTheBindingStagesPipsCountSessionOnlyForMoonlight() {
        XCTAssertEqual(setupBindingSteps(walked(to: .type)), [.type, .feel, .review])
        XCTAssertEqual(setupBindingSteps(walked(to: .type, kind: .moonlight)), [.type, .session, .feel, .review])
    }

    // MARK: - The blockers

    func testAnUnpluggedPadBlocksTheWalkUntilItIsBack() {
        let feel = walked(to: .feel)
        let gone = reduceSetup(feel, .padPresent(false)).state
        XCTAssertEqual(gone.blocker, .controllerUnplugged)
        XCTAssertFalse(setupCanAdvance(gone), "a blocked wizard does not advance")
        XCTAssertEqual(reduceSetup(gone, .next).state.step, .feel)
        XCTAssertNil(reduceSetup(gone, .padPresent(true)).state.blocker, "re-plugging keeps configuring")
    }

    func testAPadThatWasNeverPickedCannotBeUnplugged() {
        XCTAssertNil(reduceSetup(SetupWizardState(), .padPresent(false)).state.blocker)
    }

    func testAHostThatWasLiveAndDroppedIsAConnectionLost() {
        let feel = walked(to: .feel)
        let lost = run(feel, [.hostLive(true), .hostLive(false)])
        XCTAssertEqual(lost.blocker, .connectionLost)
        XCTAssertNil(reduceSetup(lost, .hostLive(true)).state.blocker, "the host coming back clears it")
    }

    func testAHostThatWasNeverLiveIsNotLost() {
        XCTAssertNil(reduceSetup(walked(to: .feel), .hostLive(false)).state.blocker)
    }

    func testAnotherDestinationForgetsThatTheOldOneWasLive() {
        let live = reduceSetup(walked(to: .type), .hostLive(true)).state
        let moved = run(live, [.back, .pickDestination("loft", .satellite), .hostLive(false)])
        XCTAssertNil(moved.blocker)
    }

    func testOnceTheApplyLandsNothingBlocks() {
        let applied = run(walked(to: .review), [.hostLive(true), .applied])
        XCTAssertTrue(applied.applied)
        XCTAssertNil(run(applied, [.hostLive(false), .padPresent(false)]).blocker)
    }

    func testStartingOverForgetsEveryAnswer() {
        let blocked = reduceSetup(walked(to: .feel), .padPresent(false)).state
        XCTAssertEqual(reduceSetup(blocked, .startOver).state, SetupWizardState())
    }

    // MARK: - The leave guard

    func testTheGuardHoldsPastTheFirstPageOnly() {
        let input = reduceSetup(SetupWizardState(), .pickPad(padDraft, hostKind: nil)).state
        XCTAssertFalse(setupLeaveGuarded(input), "an answered first page is still the first page")
        XCTAssertTrue(setupLeaveGuarded(reduceSetup(input, .next).state))
        XCTAssertTrue(setupLeaveGuarded(walked(to: .review)))
    }

    func testALandedApplyNoLongerGuards() {
        XCTAssertFalse(setupLeaveGuarded(run(walked(to: .review), [.applied])))
    }
}
