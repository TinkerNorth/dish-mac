// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Foundation

/// The deadlines of a stream paced to absolute times: frame `k` is due `k`
/// periods after the start, whatever happened to frame `k - 1`, so a late
/// frame never pushes the ones after it.
public struct PaceSchedule: Equatable, Sendable {
    public static let nsPerSecond: UInt64 = 1_000_000_000

    public let startNs: UInt64
    public let rateHz: UInt64

    public init(startNs: UInt64, rateHz: UInt64) {
        precondition(rateHz > 0, "a paced stream has a rate")
        self.startNs = startNs
        self.rateHz = rateHz
    }

    public func deadline(_ frame: UInt64) -> UInt64 {
        startNs + frame * Self.nsPerSecond / rateHz
    }

    /// The frames due in the first `durationNs` after the start.
    public func frames(within durationNs: UInt64) -> UInt64 {
        durationNs * rateHz / Self.nsPerSecond
    }
}

/// How long to sleep before spinning out the rest of the wait for
/// `deadlineNs`: until `spinNs` before it, or nil once inside that window.
public func sleepBeforeSpin(nowNs: UInt64, deadlineNs: UInt64, spinNs: UInt64) -> UInt64? {
    let spinFrom = deadlineNs > spinNs ? deadlineNs - spinNs : 0
    guard spinFrom > nowNs else { return nil }
    return spinFrom - nowNs
}

/// How a producer kept its deadlines: the frames it stamped before theirs,
/// which means the pacer was not applied, and its median lateness.
public struct PacingCheck: Equatable, Sendable {
    public static let lateLimitNs: UInt64 = 1_000_000

    public let early: Int
    public let medianLateNs: UInt64

    public init(stampsNs: [UInt64], schedule: PaceSchedule) {
        var early = 0
        var lateness: [UInt64] = []
        lateness.reserveCapacity(stampsNs.count)
        for (frame, stamp) in stampsNs.enumerated() {
            let due = schedule.deadline(UInt64(frame))
            if stamp < due { early += 1 }
            lateness.append(stamp > due ? stamp - due : 0)
        }
        lateness.sort()
        self.early = early
        medianLateNs = nearestRankPercentile(lateness, 0.5) ?? 0
    }

    /// No frame early and the median within a millisecond of its deadline.
    public var kept: Bool {
        early == 0 && medianLateNs <= Self.lateLimitNs
    }
}
