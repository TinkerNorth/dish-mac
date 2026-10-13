// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// The update checker's lifecycle machine. Every (phase, event) pair is total,
// `reduceUpdate` does no IO and reads no clock, and the effects come back as
// data for the checker to run against the network and the timers. The Mac
// client never installs its own update, so the machine stops at `available`
// and the UI links out. Ordering is by the parsed version triple only;
// `publishedAt` is display text, so a skewed clock changes nothing here.

import Foundation

public enum UpdatePhase: Equatable, Sendable {
    /// Checks are off: no timers and no network at all.
    case disabled
    /// Enabled, nothing known yet.
    case idle
    /// A manifest fetch is in flight.
    case checking
    /// The newest published release is this one, or a skipped one.
    case upToDate
    /// A newer release exists; the UI links to it.
    case available
    /// The last attempt failed; `error` says how.
    case failed
}

public enum UpdateError: Equatable, Sendable {
    case none
    /// The reachability gate; no request was made.
    case offline
    /// Transport, TLS or status code.
    case http
    /// Any manifest rejection, including a portal's HTML.
    case manifestInvalid
}

/// The checker turns these into words; the engine never vends a sentence.
public enum UpdateNotice: Equatable, Sendable {
    case available
    case unsupported
}

public enum UpdateTrigger: Equatable, Sendable {
    case startup
    case periodic
    case manual
    case retry
}

public struct UpdateStatus: Equatable, Sendable {
    public var phase = UpdatePhase.idle
    /// The running build, seeded once by the checker.
    public var currentVersion = ""
    public var availableVersion = ""
    public var notesUrl = ""
    public var minimumSupportedVersion = ""
    public var consecutiveFailures = 0
    public var error = UpdateError.none
    public var checksEnabled = true
    /// `currentVersion` is below `minimumSupportedVersion`.
    public var required = false
    /// The exact version the user muted; stays muted while the manifest
    /// still offers it.
    public var skippedVersion = ""
    /// The gate is evaluated when a check is requested, not when the
    /// connectivity event arrived.
    public var online = true

    public init(phase: UpdatePhase = .idle, currentVersion: String = "", checksEnabled: Bool = true, online: Bool = true) {
        self.phase = phase
        self.currentVersion = currentVersion
        self.checksEnabled = checksEnabled
        self.online = online
    }
}

/// The checker's schedule. Its own ladder, not the satellite reconnect one:
/// polling a release host on a seconds scale would be abuse.
public enum UpdateSchedule {
    /// The first check never competes with the first frame.
    public static let startupDelayMs = 15000
    /// A relaunch loop cannot hammer the permalink.
    public static let minCheckGapMs: Int64 = 60 * 60 * 1000
    /// A clock that reads 2099 costs one extra check, not silence.
    public static let futureSkewEscapeMs: Int64 = 24 * 60 * 60 * 1000
    public static let periodicIntervalMs = 4 * 60 * 60 * 1000
    public static let backoffBaseMs = 10 * 60 * 1000
    public static let backoffCapMs = 6 * 60 * 60 * 1000
    public static let backoffJitter = 0.2
    public static let manualMinGapMs: Int64 = 10000
    public static let reconnectCheckDelayMs = 30000

    /// 10, 20, 40 … 360 min. `failures` counts the one just recorded, so
    /// the first failure waits the base.
    public static func backoffDelayMs(failures: Int) -> Int {
        guard failures > 1 else { return backoffBaseMs }
        var delay = backoffBaseMs
        for _ in 1 ..< failures {
            delay *= 2
            if delay >= backoffCapMs { return backoffCapMs }
        }
        return delay
    }

    /// Deterministic for a `unit` in 0...1 the checker draws, so the ladder
    /// stays pinnable. Applied to failure backoff only.
    public static func jitteredDelayMs(baseMs: Int, unit: Double) -> Int {
        let clamped = min(max(unit, 0), 1)
        let factor = 1 - backoffJitter + 2 * backoffJitter * clamped
        return max(Int(Double(baseMs) * factor), 0)
    }
}

public enum UpdateEvent: Equatable, Sendable {
    /// The preference slice, republished on every store change; also how
    /// "checks off" reaches every phase.
    case prefsChanged(checksEnabled: Bool, skippedVersion: String)
    case checkRequested(UpdateTrigger)
    case manifestArrived(UpdateManifest)
    case checkFailed(UpdateError)
    case skipRequested(version: String)
    case reachabilityChanged(online: Bool)
}

public enum UpdateEffect: Equatable, Sendable {
    /// GET the permalink; `manual` only relaxes the checker's rate limit.
    case fetchManifest(manual: Bool)
    case scheduleNextCheck(delayMs: Int)
    case persistLastCheck
    case notify(UpdateNotice, version: String)
}

public struct UpdateReduction: Equatable, Sendable {
    public var next: UpdateStatus
    public var effects: [UpdateEffect]

    public init(next: UpdateStatus, effects: [UpdateEffect] = []) {
        self.next = next
        self.effects = effects
    }
}

public func reduceUpdate(_ status: UpdateStatus, _ event: UpdateEvent) -> UpdateReduction {
    switch event {
    case let .prefsChanged(checksEnabled, skippedVersion): prefsChanged(
            status,
            checksEnabled: checksEnabled,
            skippedVersion: skippedVersion
        )
    case let .checkRequested(trigger): checkRequested(status, trigger: trigger)
    case let .manifestArrived(manifest): manifestArrived(status, manifest)
    case let .checkFailed(error): checkFailed(status, error)
    case let .skipRequested(version): skipRequested(status, version: version)
    case let .reachabilityChanged(online): reachabilityChanged(status, online: online)
    }
}

private func settleFailure(_ status: UpdateStatus, _ error: UpdateError) -> UpdateReduction {
    var next = status
    next.consecutiveFailures = status.consecutiveFailures + 1
    next.phase = .failed
    next.error = error
    let delay = UpdateSchedule.backoffDelayMs(failures: next.consecutiveFailures)
    return UpdateReduction(next: next, effects: [.scheduleNextCheck(delayMs: delay)])
}

/// A failure lands only on the check in flight.
private func checkFailed(_ status: UpdateStatus, _ error: UpdateError) -> UpdateReduction {
    guard status.phase == .checking else { return UpdateReduction(next: status) }
    return settleFailure(status, error)
}

/// Off means off from every phase; re-enabling behaves like a cold start.
private func prefsChanged(_ status: UpdateStatus, checksEnabled: Bool, skippedVersion: String) -> UpdateReduction {
    var next = status
    next.checksEnabled = checksEnabled
    next.skippedVersion = skippedVersion
    if !checksEnabled {
        next.phase = .disabled
        next.error = .none
        return UpdateReduction(next: next)
    }
    if status.phase == .disabled {
        next.phase = .idle
        return UpdateReduction(next: next, effects: [.scheduleNextCheck(delayMs: UpdateSchedule.startupDelayMs)])
    }
    return UpdateReduction(next: next)
}

/// The reachability gate answers without touching the network, so a captive
/// portal never gets a request.
private func checkRequested(_ status: UpdateStatus, trigger: UpdateTrigger) -> UpdateReduction {
    if status.phase == .disabled || status.phase == .checking { return UpdateReduction(next: status) }
    if !status.online { return settleFailure(status, .offline) }
    var next = status
    next.phase = .checking
    return UpdateReduction(next: next, effects: [.fetchManifest(manual: trigger == .manual)])
}

/// Nothing to offer, or the user muted this exact version, reads up to date;
/// a skip is ignored while the running build is below the supported minimum.
private func manifestArrived(_ status: UpdateStatus, _ manifest: UpdateManifest) -> UpdateReduction {
    guard status.phase == .checking else { return UpdateReduction(next: status) }
    var next = status
    next.minimumSupportedVersion = manifest.minimumSupportedVersion
    next.required = isStrictlyNewer(manifest.minimumSupportedVersion, than: status.currentVersion)
    next.consecutiveFailures = 0
    next.error = .none
    var effects: [UpdateEffect] = [.persistLastCheck]
    let newer = isStrictlyNewer(manifest.version, than: status.currentVersion)
    let skipped = !status.skippedVersion.isEmpty && status.skippedVersion == manifest.version
    if !newer || (skipped && !next.required) {
        next.phase = .upToDate
        next.availableVersion = ""
        next.notesUrl = ""
        effects.append(.scheduleNextCheck(delayMs: UpdateSchedule.periodicIntervalMs))
        return UpdateReduction(next: next, effects: effects)
    }
    next.phase = .available
    next.availableVersion = manifest.version
    next.notesUrl = manifest.releaseNotesUrl
    if next.required { effects.append(.notify(.unsupported, version: manifest.version)) }
    effects.append(.notify(.available, version: manifest.version))
    effects.append(.scheduleNextCheck(delayMs: UpdateSchedule.periodicIntervalMs))
    return UpdateReduction(next: next, effects: effects)
}

/// A required update cannot be skipped: the build is already unsupported.
private func skipRequested(_ status: UpdateStatus, version: String) -> UpdateReduction {
    if status.required || version.isEmpty { return UpdateReduction(next: status) }
    var next = status
    next.skippedVersion = version
    if status.availableVersion == version {
        next.phase = .upToDate
        next.availableVersion = ""
        next.notesUrl = ""
    }
    return UpdateReduction(next: next)
}

/// Coming back online after an offline-gated failure re-arms one check.
private func reachabilityChanged(_ status: UpdateStatus, online: Bool) -> UpdateReduction {
    var next = status
    next.online = online
    let wasOfflineGated = status.phase == .failed && status.error == .offline && status.checksEnabled
    if online, wasOfflineGated {
        return UpdateReduction(next: next, effects: [.scheduleNextCheck(delayMs: UpdateSchedule.reconnectCheckDelayMs)])
    }
    return UpdateReduction(next: next)
}
