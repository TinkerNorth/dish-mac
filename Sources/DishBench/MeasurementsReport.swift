// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Foundation

/// A bench run as the report names it: its build, and its microphone rate
/// when that is not the default.
struct NamedRun: Equatable {
    let name: String
    let record: BenchRecord

    init(_ record: BenchRecord) {
        let build = record.settings.lockStats ? lockStatsRunName : plainRunName
        let variant = record.settings.micHz == BenchOptions.defaultMicHz ? "" : "-mic\(record.settings.micHz)"
        name = build + variant
        self.record = record
    }
}

let plainRunName = "plain"
let lockStatsRunName = "lockstats"
/// The roles the lock gate holds to no lock at all.
let lockGateRoles = ["Input", "HidReader", "Receive"]

struct LatencyEntry: Codable, Equatable {
    let run: String
    let scenario: String
    let stream: StreamResult
}

struct LockEntry: Codable, Equatable {
    let run: String
    let scenario: String
    let row: LockRow
}

struct LockViolation: Codable, Equatable {
    let run: String
    let scenario: String
    let role: String
    let lock: String
    let acquisitions: UInt64
}

/// The Input, HidReader and Receive roles take no lock in any lock-stats run.
/// A run that recorded no lock at all cannot pass, since it saw nothing.
struct LockGate: Codable, Equatable {
    let enforced: Bool
    let sawLocks: Bool
    let violations: [LockViolation]

    var passed: Bool {
        sawLocks && violations.isEmpty
    }

    var failsTheJob: Bool {
        enforced && !passed
    }
}

/// A figure more than twice the previous release's and more than 100 us
/// above it. Shared runners are noisy, so a trend only ever warns.
struct TrendWarning: Codable, Equatable {
    let run: String
    let scenario: String
    let pad: String
    let figure: String
    let previousUs: Double
    let currentUs: Double
}

struct Trend: Codable, Equatable {
    static let ratio = 2.0
    static let minimumRiseUs = 100.0

    let previous: String?
    let warnings: [TrendWarning]
}

/// What `measurements-<version>.json` holds: the gates, the reported rep's
/// figures of every run, and the runs themselves with every rep.
struct MeasurementsReport: Codable, Equatable {
    static let currentSchema = 1

    let schema: Int
    let version: String
    let commit: String?
    let machine: MachineInfo
    let settings: BenchSettings
    let lockGate: LockGate
    let trend: Trend
    let latency: [LatencyEntry]
    let locks: [LockEntry]
    let runs: [BenchRecord]
}

/// A run the report needs and did not get.
struct MissingRunError: Error, Equatable, CustomStringConvertible {
    let name: String

    var description: String {
        "no \(name) run in the input directory"
    }
}

func buildReport(
    runs: [NamedRun],
    previous: MeasurementsReport?,
    version: String,
    commit: String?,
    enforceLockGate: Bool
) throws -> MeasurementsReport {
    guard let plain = runs.first(where: { $0.name == plainRunName }) else { throw MissingRunError(name: plainRunName) }
    guard runs.contains(where: { $0.name == lockStatsRunName }) else { throw MissingRunError(name: lockStatsRunName) }
    let latency = latencyEntries(runs.filter { !$0.record.settings.lockStats })
    return MeasurementsReport(
        schema: MeasurementsReport.currentSchema,
        version: version,
        commit: commit,
        machine: plain.record.machine,
        settings: plain.record.settings,
        lockGate: lockGate(runs.filter(\.record.settings.lockStats), enforced: enforceLockGate),
        trend: Trend(previous: previous?.version, warnings: trendWarnings(latency, previous: previous?.latency ?? [])),
        latency: latency,
        locks: lockEntries(runs.filter(\.record.settings.lockStats)),
        runs: runs.map(\.record)
    )
}

func latencyEntries(_ runs: [NamedRun]) -> [LatencyEntry] {
    runs.flatMap { run in
        run.record.scenarios.flatMap { scenario in
            (scenario.reported?.streams ?? []).map { LatencyEntry(run: run.name, scenario: scenario.name, stream: $0) }
        }
    }
}

func lockEntries(_ runs: [NamedRun]) -> [LockEntry] {
    runs.flatMap { run in
        run.record.scenarios.flatMap { scenario in
            (scenario.reported?.locks ?? []).map { LockEntry(run: run.name, scenario: scenario.name, row: $0) }
        }
    }
}

func lockGate(_ lockStatsRuns: [NamedRun], enforced: Bool) -> LockGate {
    let entries = lockEntries(lockStatsRuns)
    let violations = entries
        .filter { lockGateRoles.contains($0.row.role) && $0.row.acquisitions > 0 }
        .map { LockViolation(run: $0.run, scenario: $0.scenario, role: $0.row.role, lock: $0.row.lock, acquisitions: $0.row.acquisitions) }
    return LockGate(enforced: enforced, sawLocks: !entries.isEmpty, violations: violations)
}

func trendWarnings(_ current: [LatencyEntry], previous: [LatencyEntry]) -> [TrendWarning] {
    current.flatMap { entry -> [TrendWarning] in
        let match = previous.first { $0.run == entry.run && $0.scenario == entry.scenario && $0.stream.pad == entry.stream.pad }
        guard let before = match?.stream else { return [] }
        let figures = [("p99.9", before.p999Us, entry.stream.p999Us), ("max", before.maxUs, entry.stream.maxUs)]
        return figures.compactMap { figure, previousUs, currentUs in
            let doubled = currentUs > previousUs * Trend.ratio && currentUs - previousUs > Trend.minimumRiseUs
            guard doubled else { return nil }
            return TrendWarning(
                run: entry.run,
                scenario: entry.scenario,
                pad: entry.stream.pad,
                figure: figure,
                previousUs: previousUs,
                currentUs: currentUs
            )
        }
    }
}

/// Each lock and role summed over the scenarios: acquisitions and contended
/// acquisitions added, the worst wait and hold kept.
func mergedLockRows(_ entries: [LockEntry]) -> [LockRow] {
    var merged: [String: LockRow] = [:]
    for entry in entries {
        let key = entry.row.role + " " + entry.row.lock
        guard let seen = merged[key] else {
            merged[key] = entry.row
            continue
        }
        merged[key] = LockRow(
            lock: seen.lock,
            role: seen.role,
            acquisitions: seen.acquisitions + entry.row.acquisitions,
            contended: seen.contended + entry.row.contended,
            waitMaxUs: max(seen.waitMaxUs, entry.row.waitMaxUs),
            waitP99Us: max(seen.waitP99Us, entry.row.waitP99Us),
            holdMaxUs: max(seen.holdMaxUs, entry.row.holdMaxUs),
            holdP99Us: max(seen.holdP99Us, entry.row.holdP99Us)
        )
    }
    return merged.values.sorted { (roleOrder($0.role), $0.lock) < (roleOrder($1.role), $1.lock) }
}

/// The gate's roles first, in their order, then the rest by name.
private func roleOrder(_ role: String) -> String {
    let gated = lockGateRoles.firstIndex(of: role).map { "0\($0)" }
    return gated ?? "1" + role
}
