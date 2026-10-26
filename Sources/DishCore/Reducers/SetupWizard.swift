// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// The setup wizard, the desktops' SetupWizardPage as data: the one way a
// binding is created from scratch. Six questions in three stages, every
// answer in a `BindingDraft`, nothing sent until Review's one apply.

import Foundation

/// The questions, in order. Session exists only for a Moonlight host, where
/// what the host runs is a question of its own.
public enum SetupStep: CaseIterable, Equatable, Sendable {
    case input
    case destination
    case type
    case session
    case feel
    case review
}

/// The three stages the pips draw: the pad, where it goes, how it binds.
public enum SetupStage: CaseIterable, Equatable, Sendable {
    case input
    case destination
    case binding
}

/// What the chosen destination is, which decides whether Session is asked.
public enum SetupHostKind: Equatable, Sendable {
    case satellite
    case moonlight
}

/// What stops the walk: the pad left, or a host that was live dropped.
public enum SetupBlocker: Equatable, Sendable {
    case connectionLost
    case controllerUnplugged
}

public struct SetupWizardState: Equatable, Sendable {
    public internal(set) var step: SetupStep
    /// Nil until a pad is picked.
    public internal(set) var draft: BindingDraft?
    public internal(set) var hostKind: SetupHostKind?
    /// The chosen host has been live at least once: only then can it be lost.
    public internal(set) var hostWasLive = false
    public internal(set) var blocker: SetupBlocker?
    /// The apply landed: the wizard is done and nothing blocks it any more.
    public internal(set) var applied = false

    /// A seed pre-answers the pad, so the wizard opens on Destination.
    public init(seed: BindingDraft? = nil, hostKind: SetupHostKind? = nil) {
        step = seed == nil ? .input : .destination
        draft = seed
        self.hostKind = seed == nil ? nil : hostKind
    }
}

public enum SetupWizardEvent: Equatable, Sendable {
    /// A pad picked, its draft seeded from what it is bound to now, and the
    /// kind of that binding's host.
    case pickPad(BindingDraft, hostKind: SetupHostKind?)
    case pickDestination(String, SetupHostKind)
    case edit(BindingDraftEvent)
    case next
    case back
    /// Whether the picked pad is still attached.
    case padPresent(Bool)
    /// Whether the chosen host's session is up.
    case hostLive(Bool)
    case startOver
    /// The apply landed.
    case applied
}

/// What the wizard asks of the engine, as data.
public enum SetupWizardEffect: Equatable, Sendable {
    /// Destination came up: look for hosts.
    case scan
    /// Review's one write.
    case apply(BindingDraft)
}

public struct SetupWizardStep: Equatable, Sendable {
    public let state: SetupWizardState
    public let effects: [SetupWizardEffect]
}

public func reduceSetup(_ state: SetupWizardState, _ event: SetupWizardEvent) -> SetupWizardStep {
    switch event {
    case let .pickPad(draft, kind): settled(pickedPad(state, draft, kind: kind))
    case let .pickDestination(id, kind): settled(pickedDestination(state, id, kind: kind))
    case let .edit(edit): settled(edited(state, edit))
    case .next: advanced(state)
    case .back: settled(steppedBack(state))
    case let .padPresent(present): settled(padPresence(state, present))
    case let .hostLive(live): settled(hostLink(state, live))
    case .startOver: settled(SetupWizardState())
    case .applied: settled(landed(state))
    }
}

/// The stage a step belongs to.
public func setupStage(_ step: SetupStep) -> SetupStage {
    switch step {
    case .input: .input
    case .destination: .destination
    case .type, .session, .feel, .review: .binding
    }
}

/// The binding stage's own steps, for its sub-step pips: Session only for Moonlight.
public func setupBindingSteps(_ state: SetupWizardState) -> [SetupStep] {
    SetupStep.allCases.filter { setupStage($0) == .binding && applies($0, state) }
}

/// The step's question is answered and nothing blocks the walk.
public func setupCanAdvance(_ state: SetupWizardState) -> Bool {
    guard state.blocker == nil else { return false }
    switch state.step {
    case .input: return state.draft != nil
    case .destination: return state.draft?.current.connectionId != nil
    case .type, .session, .feel, .review: return true
    }
}

/// Leaving asks first once the walk is past its first page, until the apply lands.
public func setupLeaveGuarded(_ state: SetupWizardState) -> Bool {
    let pastFirstPage = state.step != .input
    return pastFirstPage && !state.applied
}

private func settled(_ state: SetupWizardState) -> SetupWizardStep {
    SetupWizardStep(state: state, effects: [])
}

private func applies(_ step: SetupStep, _ state: SetupWizardState) -> Bool {
    step != .session || state.hostKind == .moonlight
}

private func pickedPad(_ state: SetupWizardState, _ draft: BindingDraft, kind: SetupHostKind?) -> SetupWizardState {
    guard state.draft?.slotId != draft.slotId else { return state }
    var next = state
    next.draft = draft
    next.hostKind = kind
    next.hostWasLive = false
    next.blocker = nil
    return next
}

private func pickedDestination(_ state: SetupWizardState, _ id: String, kind: SetupHostKind) -> SetupWizardState {
    guard let draft = state.draft else { return state }
    var next = state
    next.draft = reduce(draft, .chooseDestination(id))
    let moved = draft.current.connectionId != id
    next.hostKind = kind
    if moved { next.hostWasLive = false }
    return next
}

private func edited(_ state: SetupWizardState, _ edit: BindingDraftEvent) -> SetupWizardState {
    guard let draft = state.draft else { return state }
    var next = state
    next.draft = reduce(draft, edit)
    return next
}

private func advanced(_ state: SetupWizardState) -> SetupWizardStep {
    guard setupCanAdvance(state) else { return settled(state) }
    guard state.step != .review else { return applying(state) }
    var next = state
    next.step = step(after: state.step, state)
    let entersDestination = next.step == .destination
    return SetupWizardStep(state: next, effects: entersDestination ? [.scan] : [])
}

private func applying(_ state: SetupWizardState) -> SetupWizardStep {
    guard let draft = state.draft else { return settled(state) }
    return SetupWizardStep(state: state, effects: [.apply(draft)])
}

private func steppedBack(_ state: SetupWizardState) -> SetupWizardState {
    var next = state
    next.step = step(before: state.step, state)
    return next
}

/// The next step that applies; Review is the last.
private func step(after step: SetupStep, _ state: SetupWizardState) -> SetupStep {
    let later = SetupStep.allCases.drop { $0 != step }.dropFirst()
    return later.first { applies($0, state) } ?? step
}

/// The step before that applies; Input is the first.
private func step(before step: SetupStep, _ state: SetupWizardState) -> SetupStep {
    let earlier = SetupStep.allCases.prefix { $0 != step }
    return earlier.last { applies($0, state) } ?? step
}

private func padPresence(_ state: SetupWizardState, _ present: Bool) -> SetupWizardState {
    let watching = state.draft != nil && !state.applied
    guard watching else { return state }
    return blocked(state, .controllerUnplugged, when: !present)
}

private func hostLink(_ state: SetupWizardState, _ live: Bool) -> SetupWizardState {
    guard !state.applied else { return state }
    var next = state
    if live { next.hostWasLive = true }
    let lost = next.hostWasLive && !live
    return blocked(next, .connectionLost, when: lost)
}

/// Raise `blocker` while `raised`, and lower it, only it, once not.
private func blocked(_ state: SetupWizardState, _ blocker: SetupBlocker, when raised: Bool) -> SetupWizardState {
    var next = state
    if raised {
        next.blocker = blocker
    } else if state.blocker == blocker {
        next.blocker = nil
    }
    return next
}

private func landed(_ state: SetupWizardState) -> SetupWizardState {
    var next = state
    next.applied = true
    next.blocker = nil
    return next
}
