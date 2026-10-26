// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import DishEngine
import Foundation
import SwiftUI

/// What Configure binding reads: the pad it was opened for, the rows it can
/// bind to, and the shell's facts (the draft, the candidate, the apply).
struct BindingInputs {
    let slotId: String
    let slots: [ControllerSlot]
    let connections: [ConnectionSummary]
    let facts: ShellFacts
}

/// Configure binding: Input · Destination · Functions · Emulate as · What
/// carries, and the Unbind / Cancel / Apply bar. Every answer lands in the
/// draft; Apply is the one write.
struct ConfigureBindingPageState: Equatable {
    let content: BindingContent
    let overlay: ApplyOverlayState?
    let leave: LeaveDialogState
    let dirty: Bool
    /// Closing the overlay of a run that landed goes back to where the page was opened from.
    let popsOnClose: Bool
}

enum BindingContent: Equatable {
    /// The draft is being opened.
    case opening
    /// The pad left.
    case missing(title: String, body: String)
    case editing(BindingEditorState)
}

struct BindingEditorState: Equatable {
    let draft: BindingDraft
    let input: InputSectionState
    let destination: DestinationSectionState
    let functions: FunctionsSectionState
    /// Nil until a destination is picked: its kind decides the types.
    let emulate: EmulateSectionState?
    let carries: CarriesSectionState
    let bar: BindingBarState
}

struct InputSectionState: Equatable {
    let title: String
    let name: String
    let detail: String
}

struct DestinationSectionState: Equatable {
    let title: String
    let satellites: [DestinationRowState]
    let moonlightTitle: String
    let moonlight: [DestinationRowState]
    /// Nil while there is somewhere to bind to.
    let empty: EmptyHostsState?
    let manage: String
}

struct EmptyHostsState: Equatable {
    let title: String
    let message: String
}

struct DestinationRowState: Equatable, Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let chip: ChipState
    let dot: Color
    let selected: Bool
    let look: SelectionLook
}

/// A pickable row's radio glyph, its ink and the row's fill, by whether it is picked.
struct SelectionLook: Equatable {
    let glyph: String
    let ink: Color
    let fill: Color
}

func selectionLook(selected: Bool) -> SelectionLook {
    selected
        ? SelectionLook(glyph: "largecircle.fill.circle", ink: DishTheme.primary, fill: DishTheme.chipFill)
        : SelectionLook(glyph: "circle", ink: DishTheme.muted, fill: DishTheme.surfaceDim)
}

struct FunctionsSectionState: Equatable {
    let title: String
    let switches: [FunctionSwitchState]
    let touchpad: TouchpadPickState?
    /// Said when the pad has nothing to tune.
    let nothing: String?
}

struct FunctionSwitchState: Equatable, Identifiable {
    let key: SlotSwitch
    let title: String
    let detail: String
    let on: Bool

    init(_ key: SlotSwitch, _ title: String, _ detail: String, on: Bool) {
        self.key = key
        self.title = title
        self.detail = detail
        self.on = on
    }

    var id: String {
        title
    }
}

struct TouchpadPickState: Equatable {
    let title: String
    let options: [TouchpadPickOption]
    let selected: TouchpadPick
}

struct EmulateSectionState: Equatable {
    let title: String
    let options: [EmulateOption]
    let selected: Int?
    let detail: String
}

struct CarriesSectionState: Equatable {
    let title: String
    let summary: String
    let rows: [CarriesRowState]
}

struct CarriesRowState: Equatable, Identifiable {
    let id: CapFeature
    let label: String
    let verdict: String
    let color: Color
    let help: String
}

struct BindingBarState: Equatable {
    /// Present while the page opened on a binding.
    let unbind: String?
    let hint: String
    let cancel: String
    let apply: String
    let applyEnabled: Bool
}

struct LeaveDialogState: Equatable {
    let title: String
    let message: String
    let discard: String
    let keep: String
}

func configureBindingPageState(_ inputs: BindingInputs, words: L10n = .app) -> ConfigureBindingPageState {
    let binding = inputs.facts.binding
    let slot = inputs.slots.first { $0.id == inputs.slotId }
    let draft = binding.draft.flatMap { $0.slotId == inputs.slotId ? $0 : nil }
    return ConfigureBindingPageState(
        content: bindingContent(slot: slot, draft: draft, inputs, words: words),
        overlay: slot.flatMap { applyOverlay(binding.progress, pad: $0.name, host: destinationName(draft, inputs), words: words) },
        leave: LeaveDialogState(
            title: words.leaveWithoutApplying,
            message: words.changesWillBeDiscarded,
            discard: words.discard,
            keep: words.keepEditing
        ),
        dirty: draft.map(isDirty) ?? false,
        popsOnClose: binding.progress == .done
    )
}

private func bindingContent(slot: ControllerSlot?, draft: BindingDraft?, _ inputs: BindingInputs, words: L10n) -> BindingContent {
    guard let slot else { return .missing(title: words.noControllersConnected, body: words.plugOneIn) }
    guard let draft, let candidate = inputs.facts.binding.candidate else { return .opening }
    return .editing(bindingEditor(slot: slot, draft: draft, candidate: candidate, inputs, words: words))
}

private func bindingEditor(
    slot: ControllerSlot,
    draft: BindingDraft,
    candidate: ControllerSlot,
    _ inputs: BindingInputs,
    words: L10n
) -> BindingEditorState {
    let flags = effectiveFlags(global: inputs.facts.forwarding, slot: candidate.preferences)
    return BindingEditorState(
        draft: draft,
        input: InputSectionState(title: words.inputSection, name: slot.name, detail: padNodeDetail(slot, words: words)),
        destination: destinationSection(slot, draft: draft, connections: inputs.connections, words: words),
        functions: functionsSection(candidate, words: words),
        emulate: emulateSection(candidate, draft: draft, words: words),
        carries: carriesSection(capabilityTable(candidate, flags, words: words), words: words),
        bar: bindingBar(draft, progress: inputs.facts.binding.progress, words: words)
    )
}

// MARK: - Destination

func destinationSection(
    _ slot: ControllerSlot,
    draft: BindingDraft,
    connections: [ConnectionSummary],
    words: L10n = .app
) -> DestinationSectionState {
    let offered = bindableConnections(for: slot, in: connections)
    let rows = offered.map { destinationRow($0, selected: draft.current.connectionId == $0.id, words: words) }
    let satellites = zip(offered, rows).filter { $0.0.kind != .moonlight }.map(\.1)
    let hosts = zip(offered, rows).filter { $0.0.kind == .moonlight }.map(\.1)
    let empty = offered.isEmpty ? EmptyHostsState(title: words.noHostsFound, message: words.pairAHostThenBind(slot.name)) : nil
    return DestinationSectionState(
        title: words.destinationSection,
        satellites: satellites,
        moonlightTitle: words.moonlightHosts,
        moonlight: hosts,
        empty: empty,
        manage: words.manageDestinations
    )
}

private func destinationRow(_ summary: ConnectionSummary, selected: Bool, words: L10n) -> DestinationRowState {
    let subtitle = switch summary.kind {
    case .satellite, .bluetooth: connectionAddressLine(summary)
    case .moonlight: words.moonlightHostAt(summary.address)
    }
    return DestinationRowState(
        id: summary.id,
        title: connectionTitle(summary),
        subtitle: subtitle,
        chip: ChipState(text: linkStateText(summary.live, words: words), color: linkDotColor(summary.live)),
        dot: linkDotColor(summary.live),
        selected: selected,
        look: selectionLook(selected: selected)
    )
}

// MARK: - Functions and the type

/// A switch for each feature the pad has; the touchpad's pick offers the
/// mouse only where the destination grants it.
func functionsSection(_ candidate: ControllerSlot, words: L10n = .app) -> FunctionsSectionState {
    let caps = candidate.capabilities
    let choice = candidate.preferences
    let rows: [(present: Bool, row: FunctionSwitchState)] = [
        (caps.hasMotion, FunctionSwitchState(.motion, words.motion, words.motionSwitchDetail, on: choice.motion)),
        (caps.hasRumble, FunctionSwitchState(.rumble, words.rumble, words.rumbleSwitchDetail, on: choice.rumble)),
        (caps.hasMic, FunctionSwitchState(.mic, words.microphone, words.micCarriesYourVoice, on: choice.mic)),
        (caps.hasSpeaker, FunctionSwitchState(.speaker, words.controllerSound, words.hostAudioPlaysOnThePad, on: choice.speaker))
    ]
    let switches = rows.filter(\.present).map(\.row)
    let touchpad = caps.hasTouchpad
        ? TouchpadPickState(title: words.touchpad, options: touchpadPickOptions(candidate, words: words), selected: choice.touchpad)
        : nil
    let nothing = switches.isEmpty && touchpad == nil ? words.nothingToTune : nil
    return FunctionsSectionState(title: words.functionsSection, switches: switches, touchpad: touchpad, nothing: nothing)
}

/// The draft event a function switch sends.
func switchEvent(_ key: SlotSwitch, on: Bool) -> BindingDraftEvent {
    switch key {
    case .motion: .setMotion(on)
    case .rumble: .setRumble(on)
    case .touchpad: .setTouchpad(on ? .pad : .off)
    case .mic: .setMic(on)
    case .speaker: .setSpeaker(on)
    }
}

func emulateSection(_ candidate: ControllerSlot, draft: BindingDraft, words: L10n = .app) -> EmulateSectionState? {
    guard draft.current.connectionId != nil, let emulation = candidate.emulation else { return nil }
    let picker = emulatePicker(for: candidate, emulation, words: words)
    return EmulateSectionState(title: words.emulateAs, options: picker.options, selected: draft.current.emulatedType, detail: picker.detail)
}

// MARK: - What carries

func carriesSection(_ table: [CapabilityRowModel], words: L10n = .app) -> CarriesSectionState {
    let pending = table.allSatisfy { $0.verdict == .pending }
    let carried = table.filter { $0.verdict == .available }.count
    return CarriesSectionState(
        title: words.whatCarries,
        summary: pending ? words.pendingLower : words.carriedOf(carried, table.count),
        rows: table.map { row in
            CarriesRowState(
                id: row.feature,
                label: row.label,
                verdict: row.verdictText,
                color: capabilityVerdictColor(row.verdict),
                help: row.help
            )
        }
    )
}

// MARK: - The bar

func bindingBar(_ draft: BindingDraft, progress: ApplyProgress, words: L10n = .app) -> BindingBarState {
    let openedBound = draft.original.connectionId != nil
    let hint = draft.current.connectionId == nil ? words.pickADestination : words.nothingIsSentUntilYouApply
    return BindingBarState(
        unbind: openedBound ? words.unbind : nil,
        hint: hint,
        cancel: words.cancel,
        apply: openedBound ? words.apply : words.bind,
        applyEnabled: canApply(draft) && !applyInFlight(progress)
    )
}

// MARK: - The apply overlay

private func destinationName(_ draft: BindingDraft?, _ inputs: BindingInputs) -> String {
    let id = draft?.current.connectionId
    let summary = inputs.connections.first { $0.id == id }
    return summary.map(connectionTitle) ?? id ?? ""
}

/// The overlay's steps and outcome for a run: nil while none runs or waits
/// to be dismissed.
func applyOverlay(_ progress: ApplyProgress, pad: String, host: String, words: L10n = .app) -> ApplyOverlayState? {
    switch progress {
    case .idle: nil
    case .running(.binding): overlay(steps: (.active, .pending), result: nil, cancel: words.cancel, close: nil, words: words)
    case .running(.applyingOnHost): overlay(steps: (.done, .active), result: nil, cancel: nil, close: nil, words: words)
    case .done: overlay(
            steps: (.done, .done),
            result: landedLine(pad: pad, host: host, words: words),
            cancel: nil,
            close: words.done,
            words: words
        )
    case let .failed(failure): failedOverlay(failure, pad: pad, host: host, words: words)
    }
}

private func landedLine(pad: String, host: String, words: L10n) -> ApplyResultLine {
    ApplyResultLine(text: words.controllerBound(pad, host), color: DishTheme.success)
}

private func failedOverlay(_ failure: ApplyFailure, pad: String, host: String, words: L10n) -> ApplyOverlayState {
    let line = ApplyResultLine(text: failureLine(failure, pad: pad, host: host, words: words), color: DishTheme.error)
    return overlay(steps: failedSteps(failure), result: line, cancel: nil, close: words.close, words: words)
}

private func overlay(
    steps: (ApplyStepPhase, ApplyStepPhase),
    result: ApplyResultLine?,
    cancel: String?,
    close: String?,
    words: L10n
) -> ApplyOverlayState {
    ApplyOverlayState(
        eyebrow: words.applyingEyebrow,
        heading: words.applyingBinding,
        message: words.sendingEachSetting,
        steps: [
            ApplyStepRow(id: 0, title: words.binding, phase: steps.0),
            ApplyStepRow(id: 1, title: words.applyingOnTheHost, phase: steps.1)
        ],
        result: result,
        cancel: cancel,
        close: close
    )
}

/// The step that was running when the run failed is the one that failed.
private func failedSteps(_ failure: ApplyFailure) -> (ApplyStepPhase, ApplyStepPhase) {
    switch failure {
    case .cancelled, .padGone: (.failed, .pending)
    case .hostUnreachable, .rejected: (.done, .failed)
    }
}

func failureLine(_ failure: ApplyFailure, pad: String, host: String, words: L10n = .app) -> String {
    switch failure {
    case .hostUnreachable: words.couldNotReach(host)
    case .rejected: words.refusedTheBinding(host)
    case .padGone: words.noLongerAvailable(pad)
    case .cancelled: words.applyCancelled
    }
}
