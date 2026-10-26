// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import DishEngine
import Foundation
import SwiftUI

/// What the setup walk reads: the pads, the rows it can bind to, the
/// shell's facts (the walk, its draft and candidate, the scans, the apply)
/// and the pairing card open on a found satellite.
struct SetupInputs {
    let slots: [ControllerSlot]
    let connections: [ConnectionSummary]
    let facts: ShellFacts
    let openPairing: OpenPairing?
}

/// The desktops' setup wizard: the stages and their pips, one step's
/// question, the blocker that stops the walk, the pinned footer, the apply
/// overlay and the leave guard's question.
struct SetupPageState: Equatable {
    /// Nil while the walk is being opened.
    let walk: SetupWalkState?
    let leave: LeaveDialogState
    /// Leaving asks first: the walk is past its first page.
    let guarded: Bool
    /// Closing the overlay of a run that landed ends the walk.
    let landed: Bool
}

struct SetupWalkState: Equatable {
    let stages: [StepPip]
    /// The binding stage's own steps; empty before it.
    let subSteps: [StepPip]
    let content: SetupStepContent
    let blocker: BlockerCardState?
    let footer: SetupFooterState
    let overlay: ApplyOverlayState?
}

struct SetupFooterState: Equatable {
    let back: String
    let backEnabled: Bool
    let cancel: String
    let hint: String
    let primary: String
    let primaryEnabled: Bool
}

enum SetupStepContent: Equatable {
    case input(SetupInputStep)
    case destination(SetupDestinationStep)
    case type(SetupTypeStep)
    case session(SetupSessionStep)
    case feel(SetupFeelStep)
    case review(SetupReviewStep)
}

/// A step's question and the line under it.
struct SetupHeading: Equatable {
    let title: String
    let subtitle: String
}

struct SetupInputStep: Equatable {
    let heading: SetupHeading
    let pads: [SetupPadRow]
    /// The waiting state while no pad is attached.
    let waiting: EmptyStateModel?
}

struct SetupPadRow: Equatable, Identifiable {
    let id: String
    let name: String
    let detail: String
    let look: SelectionLook
}

struct SetupDestinationStep: Equatable {
    let heading: SetupHeading
    let foundTitle: String
    let scan: ScanControlState
    /// Before the first scan ever: why macOS is about to ask.
    let priming: PrimingCardState?
    let satellites: [DestinationRowState]
    let found: [FoundRowState]
    let moonlightTitle: String
    let moonlight: [DestinationRowState]
    /// Nothing to pick and nothing heard.
    let empty: NothingFoundState?
    let footnote: String
    let getApp: SettingsLinkState
}

struct SetupTypeStep: Equatable {
    let heading: SetupHeading
    let emulate: EmulateSectionState?
    /// Said while the host's catalog has not been read.
    let waiting: String?
}

struct SetupSessionStep: Equatable {
    let heading: SetupHeading
    let hostId: String
    let picker: AppPickerState?
}

struct SetupFeelStep: Equatable {
    let heading: SetupHeading
    let functions: FunctionsSectionState
    let footnote: String
}

struct SetupReviewStep: Equatable {
    let heading: SetupHeading
    let lines: [SetupReviewLine]
    let carries: CarriesSectionState
    let footnote: String
}

struct SetupReviewLine: Equatable, Identifiable {
    let label: String
    let value: String

    var id: String {
        label
    }
}

func setupPageState(_ inputs: SetupInputs, words: L10n = .app) -> SetupPageState {
    let walk = inputs.facts.setup
    return SetupPageState(
        walk: walk.map { setupWalk($0, inputs, words: words) },
        leave: LeaveDialogState(
            title: words.leaveSetup,
            message: words.nothingHasBeenSentYet,
            discard: words.discard,
            keep: words.keepSettingUp
        ),
        guarded: walk.map(setupLeaveGuarded) ?? false,
        landed: inputs.facts.binding.progress == .done
    )
}

private func setupWalk(_ walk: SetupWizardState, _ inputs: SetupInputs, words: L10n) -> SetupWalkState {
    let progress = inputs.facts.binding.progress
    let pad = setupPadName(walk, inputs)
    let host = setupHostName(walk, inputs)
    return SetupWalkState(
        stages: setupStagePips(walk.step, words: words),
        subSteps: setupSubStepPips(walk),
        content: setupContent(walk, inputs, words: words),
        blocker: walk.blocker.map { blockerCard($0, host: host, words: words) },
        footer: setupFooter(walk, progress: progress, words: words),
        overlay: applyOverlay(progress, pad: pad, host: host, words: words)
    )
}

// MARK: - The frame

func setupStagePips(_ step: SetupStep, words: L10n = .app) -> [StepPip] {
    let current = setupStage(step)
    let stages = SetupStage.allCases
    let currentIndex = stages.firstIndex(of: current) ?? 0
    return stages.enumerated().map { index, stage in
        StepPip(id: index, label: stageLabel(stage, words: words), phase: pipPhase(index, current: currentIndex))
    }
}

/// The binding stage's dots, Session among them only for Moonlight; none
/// before the stage is reached.
func setupSubStepPips(_ walk: SetupWizardState) -> [StepPip] {
    guard setupStage(walk.step) == .binding else { return [] }
    let steps = setupBindingSteps(walk)
    let currentIndex = steps.firstIndex(of: walk.step) ?? 0
    return steps.indices.map { StepPip(id: $0, label: nil, phase: pipPhase($0, current: currentIndex)) }
}

private func pipPhase(_ index: Int, current: Int) -> StepPipPhase {
    if index == current { return .current }
    return index < current ? .done : .upcoming
}

private func stageLabel(_ stage: SetupStage, words: L10n) -> String {
    switch stage {
    case .input: words.inputSection
    case .destination: words.destinationSection
    case .binding: words.binding
    }
}

/// The position always leads the hint; Review's primary is Bind.
func setupFooter(_ walk: SetupWizardState, progress: ApplyProgress, words: L10n = .app) -> SetupFooterState {
    let applying = applyInFlight(progress)
    let atStart = walk.step == .input
    return SetupFooterState(
        back: words.backChevron,
        backEnabled: !atStart && !applying,
        cancel: words.cancel,
        hint: stepPosition(walk.step, words: words),
        primary: walk.step == .review ? words.bind : words.continueChevron,
        primaryEnabled: setupCanAdvance(walk) && !applying
    )
}

private func stepPosition(_ step: SetupStep, words: L10n) -> String {
    switch step {
    case .input: words.stepInput
    case .destination: words.stepDestination
    case .type: words.stepType
    case .session: words.stepSession
    case .feel: words.stepFeel
    case .review: words.stepReview
    }
}

func blockerCard(_ blocker: SetupBlocker, host: String, words: L10n = .app) -> BlockerCardState {
    switch blocker {
    case .connectionLost: BlockerCardState(
            title: words.connectionLost,
            message: words.stoppedResponding(host),
            tone: DishTheme.error,
            startOver: words.startOver,
            exit: words.exit
        )
    case .controllerUnplugged: BlockerCardState(
            title: words.controllerUnplugged,
            message: words.holdingTheBinding,
            tone: DishTheme.warning,
            startOver: words.startOver,
            exit: words.exit
        )
    }
}

private func setupPadName(_ walk: SetupWizardState, _ inputs: SetupInputs) -> String {
    let slot = inputs.slots.first { $0.id == walk.draft?.slotId }
    return slot?.name ?? walk.draft?.slotId ?? ""
}

private func setupHostName(_ walk: SetupWizardState, _ inputs: SetupInputs) -> String {
    let id = walk.draft?.current.connectionId
    let summary = inputs.connections.first { $0.id == id }
    return summary.map(connectionTitle) ?? id ?? ""
}

// MARK: - The steps

private func setupContent(_ walk: SetupWizardState, _ inputs: SetupInputs, words: L10n) -> SetupStepContent {
    guard let draft = walk.draft else { return .input(inputStep(nil, inputs, words: words)) }
    let candidate = setupCandidate(draft, inputs)
    switch walk.step {
    case .input: return .input(inputStep(draft, inputs, words: words))
    case .destination: return .destination(destinationStep(draft, inputs, words: words))
    case .type: return .type(typeStep(walk, draft: draft, candidate: candidate, inputs, words: words))
    case .session: return .session(sessionStep(draft, inputs, words: words))
    case .feel: return .feel(feelStep(candidate, words: words))
    case .review: return .review(reviewStep(walk, candidate: candidate, inputs, words: words))
    }
}

/// The pad as the draft would bind it, or as it is while none is drawn yet.
private func setupCandidate(_ draft: BindingDraft, _ inputs: SetupInputs) -> ControllerSlot {
    let listed = inputs.slots.first { $0.id == draft.slotId }
    let fallback = listed ?? ControllerSlot(id: draft.slotId, name: draft.slotId)
    return inputs.facts.binding.candidate ?? fallback
}

func inputStep(_ draft: BindingDraft?, _ inputs: SetupInputs, words: L10n = .app) -> SetupInputStep {
    let rows = inputs.slots.map { slot in
        SetupPadRow(
            id: slot.id,
            name: slot.name,
            detail: padNodeDetail(slot, words: words),
            look: selectionLook(selected: draft?.slotId == slot.id)
        )
    }
    let waiting = EmptyStateModel(title: words.plugYourControllerIn, message: words.plugYourControllerInBody)
    let title = rows.isEmpty ? words.plugYourControllerIn : words.whichController
    return SetupInputStep(
        heading: SetupHeading(title: title, subtitle: words.eachIsDrawnAsItsNode),
        pads: rows,
        waiting: rows.isEmpty ? waiting : nil
    )
}

func destinationStep(_ draft: BindingDraft, _ inputs: SetupInputs, words: L10n = .app) -> SetupDestinationStep {
    let facts = inputs.facts.connections
    let slot = inputs.slots.first { $0.id == draft.slotId } ?? ControllerSlot(id: draft.slotId, name: draft.slotId)
    let paired = destinationSection(slot, draft: draft, connections: inputs.connections, words: words)
    let satellites = inputs.connections.filter { $0.kind == .satellite }
    let connectionsInputs = ConnectionsInputs(
        connections: inputs.connections,
        slots: inputs.slots,
        facts: facts,
        openPairing: inputs.openPairing
    )
    let found = foundServers(facts.discovered, known: satellites).map { foundRow($0, connectionsInputs, words: words) }
    let nothingToPick = paired.satellites.isEmpty && paired.moonlight.isEmpty && found.isEmpty
    let settled = facts.localNetworkPrimed && !facts.scanning
    let nothing = nothingToPick && settled
    let subtitle = facts.scanning ? words.scanningYourWifiForASatellite : words.pickThePcThisControllerShouldDrive
    return SetupDestinationStep(
        heading: SetupHeading(title: words.whichPc, subtitle: subtitle),
        foundTitle: words.found,
        scan: ScanControlState(title: facts.scanning ? words.scanning : words.rescan, enabled: !facts.scanning, showsBar: facts.scanning),
        priming: primingCard(facts, words: words),
        satellites: paired.satellites,
        found: found,
        moonlightTitle: paired.moonlightTitle,
        moonlight: paired.moonlight,
        empty: nothing ? noPcsFound(facts, words: words) : nil,
        footnote: found.isEmpty ? words.dontSeeYourPc : words.pairingIsOneTime,
        getApp: SettingsLinkState(title: words.getSatellite, url: URL(string: DishLinks.satellite))
    )
}

private func noPcsFound(_ facts: ConnectionsFacts, words: L10n) -> NothingFoundState {
    let hint = facts.localNetworkDenied ? words.localNetworkDenied : nil
    let card = EmptyStateModel(title: words.noPcsFoundYet, message: words.aPcShowsUpHere, hint: hint)
    var nothing = NothingFoundState(
        card: card,
        getApp: words.getSatellite,
        getAppURL: URL(string: DishLinks.satellite),
        secondary: words.rescan
    )
    nothing.settings = localNetworkSettings(denied: facts.localNetworkDenied, words: words)
    return nothing
}

func typeStep(
    _ walk: SetupWizardState,
    draft: BindingDraft,
    candidate: ControllerSlot,
    _ inputs: SetupInputs,
    words: L10n = .app
) -> SetupTypeStep {
    let emulate = emulateSection(candidate, draft: draft, words: words)
    let heading = switch walk.hostKind {
    case .moonlight: SetupHeading(title: words.howShouldTheHostSeeIt, subtitle: words.dishAsksTheHostToPlugIn(setupHostName(walk, inputs)))
    case .satellite, nil: SetupHeading(title: words.howShouldThePcSeeIt, subtitle: words.pickTheControllerThePcShouldReport)
    }
    return SetupTypeStep(heading: heading, emulate: emulate, waiting: emulate == nil ? words.waitingOnTheType : nil)
}

func sessionStep(_ draft: BindingDraft, _ inputs: SetupInputs, words: L10n = .app) -> SetupSessionStep {
    let hostId = draft.current.connectionId ?? ""
    let summary = inputs.connections.first { $0.id == hostId }
    let host = summary.map(connectionTitle) ?? hostId
    return SetupSessionStep(
        heading: SetupHeading(title: words.session, subtitle: words.withoutAPick(host)),
        hostId: hostId,
        picker: appPicker(hostId, host: host, facts: inputs.facts.connections.moonlight, words: words)
    )
}

func feelStep(_ candidate: ControllerSlot, words: L10n = .app) -> SetupFeelStep {
    SetupFeelStep(
        heading: SetupHeading(title: words.howShouldItFeel, subtitle: words.onlyTheExtrasBothSupport),
        functions: functionsSection(candidate, words: words),
        footnote: words.nothingHereIsSavedYet
    )
}

/// The binding as it will be drawn: the pad, where it goes and as what,
/// and what carries there; Bind is the first write.
func reviewStep(_ walk: SetupWizardState, candidate: ControllerSlot, _ inputs: SetupInputs, words: L10n = .app) -> SetupReviewStep {
    let host = setupHostName(walk, inputs)
    let flags = effectiveFlags(global: inputs.facts.forwarding, slot: candidate.preferences)
    return SetupReviewStep(
        heading: SetupHeading(title: words.reviewAndBind, subtitle: words.everythingAboveIsDecided),
        lines: [
            SetupReviewLine(label: words.inputSection, value: setupPadName(walk, inputs)),
            SetupReviewLine(label: words.destinationSection, value: host),
            SetupReviewLine(label: words.type, value: emulatedTypeName(candidate.emulation, words: words))
        ],
        carries: carriesSection(capabilityTable(candidate, flags, words: words), words: words),
        footnote: words.nothingOnTheHostHasChangedYet(host)
    )
}
