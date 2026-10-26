// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// One binding apply as the "Applying binding…" overlay shows it, the
// desktops' apply sequencer: the binding is written, then the host is asked
// to carry it, then it is done or it failed, exactly once per run.

import Foundation

public enum ApplyStep: Equatable, Sendable {
    /// Written here, waiting for the host's link before the PUT goes out.
    case binding
    /// The PUT is out and the host has not answered.
    case applyingOnHost
}

public enum ApplyFailure: Equatable, Sendable {
    /// The budget ran out before the host answered.
    case hostUnreachable
    /// The host refused the controller.
    case rejected
    /// The pad left before the run ended.
    case padGone
    /// The user cancelled while the binding waited for its link.
    case cancelled
}

public enum ApplyProgress: Equatable, Sendable {
    case idle
    case running(ApplyStep)
    case done
    case failed(ApplyFailure)
}

/// How a run starts: the host's session takes the PUT at once, the link has
/// to come up first, or the binding is a durable intent the host takes when
/// the pad is used (a Moonlight host).
public enum ApplyPath: Equatable, Sendable {
    case hostLive
    case waitingForLink
    case durable
}

public enum ApplyEvent: Equatable, Sendable {
    case started(ApplyPath)
    case putSent
    case hostConfirmed
    case hostRejected
    case budgetSpent
    case padGone
    case cancelled
    case dismissed
}

/// One step of a run. A running apply takes the host's words; an ended one
/// ignores them until it is dismissed or a new run starts.
public func reduceApply(_ progress: ApplyProgress, _ event: ApplyEvent) -> ApplyProgress {
    switch progress {
    case .idle: idleApply(event)
    case let .running(step): runningApply(step, event)
    case .done, .failed: endedApply(progress, event)
    }
}

private func idleApply(_ event: ApplyEvent) -> ApplyProgress {
    switch event {
    case let .started(path): startedApply(path)
    case .padGone: .failed(.padGone)
    case .putSent, .hostConfirmed, .hostRejected, .budgetSpent, .cancelled, .dismissed: .idle
    }
}

private func startedApply(_ path: ApplyPath) -> ApplyProgress {
    switch path {
    case .hostLive: .running(.applyingOnHost)
    case .waitingForLink: .running(.binding)
    case .durable: .done
    }
}

private func runningApply(_ step: ApplyStep, _ event: ApplyEvent) -> ApplyProgress {
    switch event {
    case .putSent: .running(.applyingOnHost)
    case .hostConfirmed: .done
    case .hostRejected: .failed(.rejected)
    case .budgetSpent: .failed(.hostUnreachable)
    case .padGone: .failed(.padGone)
    case .cancelled: cancelledApply(step)
    case .started, .dismissed: .running(step)
    }
}

/// Cancel ends a run that waits for its link; the PUT, once out, runs on.
private func cancelledApply(_ step: ApplyStep) -> ApplyProgress {
    switch step {
    case .binding: .failed(.cancelled)
    case .applyingOnHost: .running(.applyingOnHost)
    }
}

private func endedApply(_ progress: ApplyProgress, _ event: ApplyEvent) -> ApplyProgress {
    switch event {
    case let .started(path): startedApply(path)
    case .dismissed: .idle
    case .putSent, .hostConfirmed, .hostRejected, .budgetSpent, .padGone, .cancelled: progress
    }
}

/// Cancel is honoured only before the PUT: the REST round trip cannot be
/// half applied.
public func applyCancellable(_ progress: ApplyProgress) -> Bool {
    progress == .running(.binding)
}

public func applyInFlight(_ progress: ApplyProgress) -> Bool {
    switch progress {
    case .running: true
    case .idle, .done, .failed: false
    }
}
