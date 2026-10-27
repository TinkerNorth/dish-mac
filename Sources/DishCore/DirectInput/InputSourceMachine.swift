// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// One pad's input source as a pure machine: which source is forwarded, why,
// whether a real change has proven it, and the "Not responding?" check that
// watches both paths. Every (phase, event) pair is total, the reducer reads
// no clock (instants arrive in the events), and the effects come back as
// data for the engine to run. The source is sticky for a connection: only
// the user's pick moves it, so the two paths never flap.

import Foundation

public enum InputSourcePhase: Equatable, Sendable {
    case disconnected
    /// Connected, waiting for GameController's support to settle.
    case awaitingGameController
    case forwarding(InputSource)
    /// Connected, and neither path reads it.
    case unreadable
}

/// A running check: when it started and which paths have reported a change.
public struct PadCheck: Equatable, Sendable {
    public let startedAtMs: Int64
    public var sawStandard = false
    public var sawDirect = false

    public init(startedAtMs: Int64) {
        self.startedAtMs = startedAtMs
    }

    func saw(_ source: InputSource) -> Bool {
        switch source {
        case .standard: sawStandard
        case .direct: sawDirect
        }
    }
}

public enum InputCheckWindow {
    public static let durationMs: Int64 = 5000
}

public enum CheckVerdict: Equatable, Sendable {
    /// macOS passes the pad's input.
    case standardWorks
    /// Dish's own reader sees the pad's input.
    case dishReadsIt
    /// Nothing arrived, and Dish has no decoder for the pad.
    case noDecoder
    /// Nothing arrived on either path.
    case nothingAtAll
}

/// The one action a verdict offers.
public enum CheckOffer: Equatable, Sendable {
    case none
    case useDirect
    case helpSupport
    case connectionHint
}

public enum InputSourceEvent: Equatable, Sendable {
    case connected(PadPathFacts)
    case gameControllerResolved(shows: Bool)
    /// A GameController value change.
    case standardInputChanged(nowMs: Int64)
    /// A change in the decoded report: buttons, sticks or triggers, never
    /// motion or battery.
    case directInputChanged(nowMs: Int64)
    case checkStarted(nowMs: Int64)
    case tick(nowMs: Int64)
    case userPicked(InputSource)
    case disconnected
}

public enum InputSourceEffect: Equatable, Sendable {
    case forward(InputSource)
    case stopForwarding
    /// Store the pick under the model's `usb_path_choices` key.
    case remember(InputSource)
    case verdict(CheckVerdict, offer: CheckOffer)
}

public struct InputSourceState: Equatable, Sendable {
    public var phase = InputSourcePhase.disconnected
    public var reason: InputSourceReason?
    /// A real change has arrived on the forwarded source.
    public var proven = false
    public var check: PadCheck?
    /// What the engine reported at connect, and GameController's later answer.
    public var facts = PadPathFacts.unknown

    public init() {}

    public static let initial = InputSourceState()

    /// Whether the user may move the pad onto `source` now.
    public func canPick(_ source: InputSource) -> Bool {
        guard case let .forwarding(current) = phase, current != source else { return false }
        return pathAvailable(source, facts)
    }
}

public struct InputSourceReduction: Equatable, Sendable {
    public var next: InputSourceState
    public var effects: [InputSourceEffect]

    public init(next: InputSourceState, effects: [InputSourceEffect] = []) {
        self.next = next
        self.effects = effects
    }
}

public func reduceInputSource(_ state: InputSourceState, _ event: InputSourceEvent) -> InputSourceReduction {
    switch state.phase {
    case .disconnected: whileDisconnected(state, event)
    case .awaitingGameController: whileAwaiting(state, event)
    case let .forwarding(source): whileForwarding(state, source, event)
    case .unreadable: whileUnreadable(state, event)
    }
}

// MARK: - Deciding

private func settle(_ facts: PadPathFacts) -> InputSourceReduction {
    var next = InputSourceState()
    next.facts = facts
    switch decidePath(facts) {
    case let .forward(source, reason):
        next.phase = .forwarding(source)
        next.reason = reason
        return InputSourceReduction(next: next, effects: [.forward(source)])
    case .awaitGameController:
        next.phase = .awaitingGameController
        return InputSourceReduction(next: next)
    case .unreadable:
        next.phase = .unreadable
        return InputSourceReduction(next: next)
    }
}

private func whileDisconnected(_ state: InputSourceState, _ event: InputSourceEvent) -> InputSourceReduction {
    guard case let .connected(facts) = event else { return InputSourceReduction(next: state) }
    return settle(facts)
}

private func whileAwaiting(_ state: InputSourceState, _ event: InputSourceEvent) -> InputSourceReduction {
    switch event {
    case let .gameControllerResolved(shows):
        var facts = state.facts
        facts.gameController = shows ? .shows : .doesNotShow
        return settle(facts)
    case .disconnected:
        return InputSourceReduction(next: .initial)
    case .connected, .standardInputChanged, .directInputChanged, .checkStarted, .tick, .userPicked:
        return InputSourceReduction(next: state)
    }
}

/// Nothing is forwarded, so only the end of the connection matters.
private func whileUnreadable(_ state: InputSourceState, _ event: InputSourceEvent) -> InputSourceReduction {
    guard event == .disconnected else { return InputSourceReduction(next: state) }
    return InputSourceReduction(next: .initial)
}

// MARK: - Forwarding

private func whileForwarding(_ state: InputSourceState, _ source: InputSource, _ event: InputSourceEvent) -> InputSourceReduction {
    switch event {
    case .connected:
        InputSourceReduction(next: state)
    case let .gameControllerResolved(shows):
        recordSupport(state, shows: shows)
    case let .standardInputChanged(nowMs):
        inputChanged(state, forwarded: source, changed: .standard, nowMs: nowMs)
    case let .directInputChanged(nowMs):
        inputChanged(state, forwarded: source, changed: .direct, nowMs: nowMs)
    case let .checkStarted(nowMs):
        startCheck(state, nowMs: nowMs)
    case let .tick(nowMs):
        concludeIfDue(state, forwarded: source, nowMs: nowMs)
    case let .userPicked(picked):
        pick(state, picked)
    case .disconnected:
        InputSourceReduction(next: .initial, effects: [.stopForwarding])
    }
}

/// A support answer after the decision is kept for the pick rules and never
/// moves the source.
private func recordSupport(_ state: InputSourceState, shows: Bool) -> InputSourceReduction {
    var next = state
    next.facts.gameController = shows ? .shows : .doesNotShow
    return InputSourceReduction(next: next)
}

/// A check already running keeps its start.
private func startCheck(_ state: InputSourceState, nowMs: Int64) -> InputSourceReduction {
    guard state.check == nil else { return InputSourceReduction(next: state) }
    var next = state
    next.check = PadCheck(startedAtMs: nowMs)
    return InputSourceReduction(next: next)
}

private func pick(_ state: InputSourceState, _ picked: InputSource) -> InputSourceReduction {
    guard state.canPick(picked) else { return InputSourceReduction(next: state) }
    var next = state
    next.phase = .forwarding(picked)
    next.reason = .userPicked
    next.proven = false
    next.check = nil
    return InputSourceReduction(next: next, effects: [.forward(picked), .remember(picked)])
}

private func windowClosed(_ check: PadCheck, nowMs: Int64) -> Bool {
    nowMs - check.startedAtMs >= InputCheckWindow.durationMs
}

private func concludeIfDue(_ state: InputSourceState, forwarded: InputSource, nowMs: Int64) -> InputSourceReduction {
    guard let check = state.check, windowClosed(check, nowMs: nowMs) else { return InputSourceReduction(next: state) }
    return conclude(state, check, forwarded: forwarded)
}

/// A change past the window first closes the check on what it had seen,
/// then counts as an ordinary change. A change on the forwarded source
/// proves it, and settles a running check at once.
private func inputChanged(
    _ state: InputSourceState,
    forwarded: InputSource,
    changed: InputSource,
    nowMs: Int64
) -> InputSourceReduction {
    let closed = concludeIfDue(state, forwarded: forwarded, nowMs: nowMs)
    var next = closed.next
    let onForwarded = changed == forwarded
    if onForwarded { next.proven = true }
    guard var check = next.check else { return InputSourceReduction(next: next, effects: closed.effects) }
    switch changed {
    case .standard: check.sawStandard = true
    case .direct: check.sawDirect = true
    }
    next.check = check
    guard onForwarded else { return InputSourceReduction(next: next, effects: closed.effects) }
    return conclude(next, check, forwarded: forwarded)
}

private func conclude(_ state: InputSourceState, _ check: PadCheck, forwarded: InputSource) -> InputSourceReduction {
    var next = state
    next.check = nil
    let decodable = state.facts.decodable
    let (verdict, offer) = checkVerdict(check, forwarded: forwarded, decodable: decodable)
    return InputSourceReduction(next: next, effects: [.verdict(verdict, offer: offer)])
}

/// The forwarded path's own change answers first; the other path's change
/// names what would work; silence is a connection problem when Dish could
/// have decoded the pad, and a pad to support when it could not.
public func checkVerdict(_ check: PadCheck, forwarded: InputSource, decodable: Bool) -> (CheckVerdict, CheckOffer) {
    let other: InputSource = forwarded == .standard ? .direct : .standard
    if check.saw(forwarded) { return (verdictFor(forwarded), .none) }
    if check.saw(other) { return (verdictFor(other), other == .direct ? .useDirect : .none) }
    return decodable ? (.nothingAtAll, .connectionHint) : (.noDecoder, .helpSupport)
}

private func verdictFor(_ source: InputSource) -> CheckVerdict {
    switch source {
    case .standard: .standardWorks
    case .direct: .dishReadsIt
    }
}
