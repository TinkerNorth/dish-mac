// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import Foundation

/// One pad's reports in one rep, from their publish to the satellite's decrypt.
struct StreamResult: Codable, Equatable {
    let pad: String
    let source: String
    let rateHz: Int
    let frames: Int
    let received: Int
    let p50Us: Double
    let p99Us: Double
    let p999Us: Double
    let maxUs: Double
    let overOneMs: Int
    let longestGapMs: Double
    /// Every uplink datagram naming the pad, over the reports it was fed.
    let datagramsPerReport: Double
    let drops: Int
}

/// How one pacer kept its deadlines.
struct PacingResult: Codable, Equatable {
    let stream: String
    let rateHz: Int
    let frames: Int
    let early: Int
    let medianLateUs: Double
    let kept: Bool
}

/// The commands the satellite sent and what the return paths asked of the pads.
struct FeedbackResult: Codable, Equatable {
    let rumbleSent: Int
    let lightbarSent: Int
    let rumbleApplied: Int
    let lightbarApplied: Int
}

/// One lock on one thread role, in a LOCK_STATS build.
struct LockRow: Codable, Equatable {
    let lock: String
    let role: String
    let acquisitions: UInt64
    let contended: UInt64
    let waitMaxUs: Double
    let waitP99Us: Double
    let holdMaxUs: Double
    let holdP99Us: Double
}

/// A nesting edge (outer, inner) or a blocking call and a lock held across it.
struct PairRow: Codable, Equatable {
    let first: String
    let second: String
    let count: UInt64
}

/// One rep of one scenario.
struct RepResult: Codable, Equatable {
    let streams: [StreamResult]
    let pacing: [PacingResult]
    let feedback: FeedbackResult?
    /// Routing-table refreshes the main actor ran, and the tally it last read.
    let refreshes: Int
    let talliedReports: UInt64
    let locks: [LockRow]
    let nesting: [PairRow]
    let blocking: [PairRow]
}

struct ScenarioResult: Codable, Equatable {
    let name: String
    let summary: String
    /// The rep whose pad A p99.9 is the median.
    let reportedRep: Int
    let reps: [RepResult]

    var reported: RepResult? {
        reps.indices.contains(reportedRep) ? reps[reportedRep] : nil
    }
}

struct BenchSettings: Codable, Equatable {
    let rateHz: Int
    let secs: Double
    let reps: Int
    let micHz: Int
    let smoke: Bool
    let lockStats: Bool
    /// How long before each deadline a pacer stops sleeping and spins.
    let spinUs: Double
    let scenarios: [String]
}

/// One bench invocation: what `--json` writes and the report reads.
struct BenchRecord: Codable, Equatable {
    static let currentSchema = 1

    let schema: Int
    let settings: BenchSettings
    let machine: MachineInfo
    let scenarios: [ScenarioResult]
}

extension StreamResult {
    init(_ summary: LatencySummary, pad: String, source: String, rateHz: Int, datagrams: Int) {
        self.init(
            pad: pad,
            source: source,
            rateHz: rateHz,
            frames: summary.frames,
            received: summary.received,
            p50Us: microseconds(summary.p50Ns),
            p99Us: microseconds(summary.p99Ns),
            p999Us: microseconds(summary.p999Ns),
            maxUs: microseconds(summary.maxNs),
            overOneMs: summary.overLimit,
            longestGapMs: microseconds(summary.longestGapNs) / 1000,
            datagramsPerReport: summary.frames > 0 ? Double(datagrams) / Double(summary.frames) : 0,
            drops: summary.drops
        )
    }
}

extension PacingResult {
    init(_ check: PacingCheck, stream: String, rateHz: Int, frames: Int) {
        self.init(
            stream: stream,
            rateHz: rateHz,
            frames: frames,
            early: check.early,
            medianLateUs: microseconds(check.medianLateNs),
            kept: check.kept
        )
    }
}
