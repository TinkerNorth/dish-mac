// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// The Moonlight session's lifecycle as a pure, total (state, event) ->
// (state, effects) reducer. The engine turns network completions into
// events, runs the reducer, and executes the effects against its HTTP, RTSP
// and ENet edges; ports and keys are transport data and stay with it.
//
// Happy path: idle -> checkingInfo -> launching -> rtsp(options ... play) ->
// controlConnecting -> streaming. Every failure lands in failed(reason) with
// teardown effects; a stop tears down from any phase and returns to idle.

import Foundation

public enum MoonlightRtspStep: Int, CaseIterable, Equatable, Sendable {
    case options
    case describe
    case setupAudio
    case setupVideo
    case setupControl
    case announce
    case play

    var next: MoonlightRtspStep? {
        MoonlightRtspStep(rawValue: rawValue + 1)
    }
}

public enum MoonlightSessionFailure: Equatable, Sendable {
    /// /serverinfo never answered.
    case unreachable
    /// The host answered, and this client is not paired.
    case notPaired
    /// The host answered unpaired, and a pairing with it is remembered.
    case trustLost
    /// The host answered with an identity the remembered pairing does not anchor.
    case hostReplaced
    /// The host lists no app and nothing was picked.
    case noApps
    /// The app picked for the host is no longer on its list; the pick is the user's to change.
    case appRemoved
    /// /launch or /resume returned no session.
    case launchRejected
    /// The host holds an app and would not hand it over.
    case appAlreadyRunning
    /// /resume was offered, then the host would not hand the app back.
    case resumeFailed
    /// An RTSP step failed or its transport dropped.
    case rtspRejected
    /// The control stream never came up.
    case controlLost
    /// The live link died; the host usually lets it resume.
    case dropped
    /// The host sent TERMINATION.
    case hostEnded
}

public enum MoonlightSessionPhase: Equatable, Sendable {
    case idle
    case checkingInfo
    case launching
    case rtsp(MoonlightRtspStep)
    case controlConnecting
    case streaming
    case failed(MoonlightSessionFailure)
}

public struct MoonlightSessionMachineState: Equatable, Sendable {
    public var phase: MoonlightSessionPhase = .idle
    /// The host refused the launch with an app of ours already running and
    /// offered to hand it back: the next launch is a /resume.
    public var resuming = false

    public init(phase: MoonlightSessionPhase = .idle, resuming: Bool = false) {
        self.phase = phase
        self.resuming = resuming
    }
}

public enum MoonlightSessionEvent: Equatable, Sendable {
    case startRequested
    /// `paired` is PairStatus for this client over mutual TLS; `remembered`
    /// is a stored pairing with this host; `identityChanged` is a uniqueid
    /// that is not the one remembered.
    case serverInfoOk(paired: Bool, remembered: Bool, identityChanged: Bool)
    case serverInfoFailed
    case noAppsAvailable
    /// The remembered pick is no longer on the host's list.
    case pickedAppRemoved
    case launchOk
    case launchFailed
    /// The host refused in the body with an app already running; `resumable` is its `<resume>`.
    case launchBusy(resumable: Bool)
    case rtspReady
    case rtspStepOk
    case rtspFailed
    case controlConnected
    case controlLost
    case hostTerminated
    case stopRequested
}

public enum MoonlightSessionEffect: Equatable, Sendable {
    case fetchServerInfo
    /// /launch, or /resume when the state says so.
    case sendLaunch
    case openRtsp
    case sendRtsp(MoonlightRtspStep)
    /// ENet connect with the SETUP's port and connect data.
    case connectControl
    /// Arrivals and the media pings.
    case startStreaming
    case sendTermination
    case teardown
    case notifyFailure
}

public struct MoonlightSessionReduction: Equatable, Sendable {
    /// Nil: the event does not apply in this phase and the state is unchanged.
    public var next: MoonlightSessionMachineState?
    public var effects: [MoonlightSessionEffect]

    public init(next: MoonlightSessionMachineState?, effects: [MoonlightSessionEffect] = []) {
        self.next = next
        self.effects = effects
    }

    static let ignored = MoonlightSessionReduction(next: nil)
}

/// A session starts only from a resting phase: a second binding on a host
/// that is checking, launching or live joins it and announces only itself.
public func moonlightSessionNeedsStart(_ phase: MoonlightSessionPhase) -> Bool {
    switch phase {
    case .idle, .failed: true
    case .checkingInfo, .launching, .rtsp, .controlConnecting, .streaming: false
    }
}

/// Whether a teardown owes the host a /cancel: a launch that never went live
/// left the host holding an app on our behalf; one that did is left alone
/// while someone still rides it, and handed back once the last pad leaves.
public func shouldHandBackApp(launched: Bool, wentLive: Bool, lastControllerLeft: Bool) -> Bool {
    launched && (!wentLive || lastControllerLeft)
}

/// Pure and total: every phase answers every event, and a stray late
/// completion is ignored rather than allowed to corrupt the lifecycle.
public func reduceMoonlightSession(_ state: MoonlightSessionMachineState, _ event: MoonlightSessionEvent) -> MoonlightSessionReduction {
    if event == .stopRequested { return stopFrom(state) }
    switch state.phase {
    case .idle, .failed: return fromIdle(event)
    case .checkingInfo: return fromCheckingInfo(state, event)
    case .launching: return fromLaunching(state, event)
    case let .rtsp(step): return fromRtsp(state, step: step, event)
    case .controlConnecting: return fromControlConnecting(state, event)
    case .streaming: return fromStreaming(state, event)
    }
}

private func fail(_ state: MoonlightSessionMachineState, _ reason: MoonlightSessionFailure) -> MoonlightSessionReduction {
    var next = state
    next.phase = .failed(reason)
    return MoonlightSessionReduction(next: next, effects: [.teardown, .notifyFailure])
}

/// Stop wins from every phase; only a link that reached the control stream is told it is ending.
private func stopFrom(_ state: MoonlightSessionMachineState) -> MoonlightSessionReduction {
    var effects: [MoonlightSessionEffect] = []
    switch state.phase {
    case .streaming, .controlConnecting: effects = [.sendTermination, .teardown]
    case .checkingInfo, .launching, .rtsp, .failed: effects = [.teardown]
    case .idle: effects = []
    }
    return MoonlightSessionReduction(next: MoonlightSessionMachineState(), effects: effects)
}

/// A failed session is restarted, never resumed in place.
private func fromIdle(_ event: MoonlightSessionEvent) -> MoonlightSessionReduction {
    guard event == .startRequested else { return .ignored }
    return MoonlightSessionReduction(next: MoonlightSessionMachineState(phase: .checkingInfo), effects: [.fetchServerInfo])
}

private func fromCheckingInfo(_ state: MoonlightSessionMachineState, _ event: MoonlightSessionEvent) -> MoonlightSessionReduction {
    switch event {
    case let .serverInfoOk(paired, remembered, identityChanged):
        // A host with another identity is not the one the stored pairing anchors;
        // re-pairing is the only way back, so it is named before pairing is judged.
        if identityChanged { return fail(state, .hostReplaced) }
        if !paired { return fail(state, remembered ? .trustLost : .notPaired) }
        var next = state
        next.phase = .launching
        // A running app is asked for with a /launch first, as every client
        // does: the host says whether it is ours to resume.
        next.resuming = false
        return MoonlightSessionReduction(next: next, effects: [.sendLaunch])
    case .serverInfoFailed:
        return fail(state, .unreachable)
    default:
        return .ignored
    }
}

private func fromLaunching(_ state: MoonlightSessionMachineState, _ event: MoonlightSessionEvent) -> MoonlightSessionReduction {
    switch event {
    case .launchOk:
        var next = state
        next.phase = .rtsp(.options)
        return MoonlightSessionReduction(next: next, effects: [.openRtsp])
    case let .launchBusy(resumable):
        // One resume, only when the host offered it: a second busy after
        // resuming is the host keeping the app, not a reason to ask again.
        guard resumable, !state.resuming else { return fail(state, .appAlreadyRunning) }
        var next = state
        next.resuming = true
        return MoonlightSessionReduction(next: next, effects: [.sendLaunch])
    case .launchFailed:
        // A failed /resume is not a refused /launch: the host has the session
        // and would not hand it back, which closing the app fixes, not a retry.
        return fail(state, state.resuming ? .resumeFailed : .launchRejected)
    case .noAppsAvailable:
        return fail(state, .noApps)
    case .pickedAppRemoved:
        return fail(state, .appRemoved)
    default:
        return .ignored
    }
}

/// One step per reply, in the steps' order; play hands over to the control stream.
private func fromRtsp(
    _ state: MoonlightSessionMachineState,
    step: MoonlightRtspStep,
    _ event: MoonlightSessionEvent
) -> MoonlightSessionReduction {
    switch event {
    case .rtspReady:
        guard step == .options else { return .ignored }
        return MoonlightSessionReduction(next: state, effects: [.sendRtsp(.options)])
    case .rtspStepOk:
        var next = state
        guard let following = step.next else {
            next.phase = .controlConnecting
            return MoonlightSessionReduction(next: next, effects: [.connectControl])
        }
        next.phase = .rtsp(following)
        return MoonlightSessionReduction(next: next, effects: [.sendRtsp(following)])
    case .rtspFailed:
        return fail(state, .rtspRejected)
    default:
        return .ignored
    }
}

private func fromControlConnecting(_ state: MoonlightSessionMachineState, _ event: MoonlightSessionEvent) -> MoonlightSessionReduction {
    switch event {
    case .controlConnected:
        var next = state
        next.phase = .streaming
        return MoonlightSessionReduction(next: next, effects: [.startStreaming])
    case .controlLost: return fail(state, .controlLost)
    case .hostTerminated: return fail(state, .hostEnded)
    default: return .ignored
    }
}

/// A link that dies after going live is a drop, not a setup failure: the
/// host keeps the app and usually lets it resume.
private func fromStreaming(_ state: MoonlightSessionMachineState, _ event: MoonlightSessionEvent) -> MoonlightSessionReduction {
    switch event {
    case .controlLost: fail(state, .dropped)
    case .hostTerminated: fail(state, .hostEnded)
    default: .ignored
    }
}

/// What a host's session must do next for the pads bound to it: the first
/// pad opens the stream, later pads only announce themselves on the one
/// already up, a launch in flight is left alone, and losing the last pad
/// releases the host, closing the app it started only when a session came up.
public enum MoonlightConverge: Equatable, Sendable {
    case open
    case announce
    case wait
    case release
    case cancel
}

public func moonlightConverge(phase: MoonlightSessionPhase, wantedPads: Int) -> MoonlightConverge {
    switch (phase, wantedPads) {
    case (.streaming, 0): .cancel
    case (_, 0): .release
    case (.streaming, _): .announce
    case (.checkingInfo, _), (.launching, _), (.rtsp, _), (.controlConnecting, _): .wait
    case (.idle, _), (.failed, _): .open
    }
}
