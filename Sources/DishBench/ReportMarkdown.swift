// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Foundation

/// `measurements-<version>.md`, the job summary: the gates, the latency of
/// every pad, and the locks each thread role took.
func renderReport(_ report: MeasurementsReport) -> String {
    let sections = [
        ["# Dish Mac measurements \(report.version)", "", provenance(report), ""],
        gateSection(report),
        latencySection(report),
        lockSection(report)
    ]
    return sections.flatMap { $0 }.joined(separator: "\n") + "\n"
}

private func provenance(_ report: MeasurementsReport) -> String {
    let machine = report.machine
    let settings = report.settings
    let commit = report.commit.map { "Commit `\($0)`. " } ?? ""
    let host = "\(machine.cpu), \(machine.model), \(machine.cores) cores, \(fixed(machine.memoryGB)) GB, \(machine.os)"
    let shape = "\(fixed(settings.secs)) s x \(settings.reps) reps after a warm-up, pad A at \(settings.rateHz) Hz"
    let waits = settings.timeConstrained ? "time-constrained waits woke" : "waits, with no time constraint granted, woke"
    let late = fixed(settings.timerLateP90Us, digits: 0)
    let timer = "\(waits) \(late) us late at p90, so pacers spin \(fixed(settings.spinUs, digits: 0)) us"
    return commit + "Measured on \(host). Each scenario: \(shape); \(timer)."
}

private func gateSection(_ report: MeasurementsReport) -> [String] {
    var lines = ["## Gates", "", lockGateLine(report.lockGate), trendLine(report.trend), ""]
    if !report.lockGate.violations.isEmpty {
        lines += ["### Locks on the gated roles", ""]
        lines += markdownHeader(["run", "scenario", "role", "lock", "acquisitions"], textColumns: 4)
        lines += report.lockGate.violations.map { violation in
            "| \(violation.run) | \(violation.scenario) | \(violation.role) | \(violation.lock) | \(violation.acquisitions) |"
        }
        lines.append("")
    }
    if !report.trend.warnings.isEmpty {
        lines += ["### Trend warnings", ""]
        lines += markdownHeader(["run", "scenario", "pad", "figure", "previous us", "now us"], textColumns: 4)
        lines += report.trend.warnings.map { warning in
            let cells = [warning.run, warning.scenario, warning.pad, warning.figure, fixed(warning.previousUs), fixed(warning.currentUs)]
            return "| " + cells.joined(separator: " | ") + " |"
        }
        lines.append("")
    }
    return lines
}

private func lockGateLine(_ gate: LockGate) -> String {
    let rule = "the Input, HidReader and Receive roles take no lock in the lock-stats runs"
    let enforcement = gate.enforced
        ? "Enforced: a failure fails the job."
        : "Reported, not enforced: the release workflow passes `--enforce-lock-gate`, which fails the job on it."
    let verdict = if !gate.sawLocks {
        "**FAIL**: the lock-stats runs recorded no lock at all, so nothing was judged."
    } else if gate.passed {
        "**PASS**."
    } else {
        "**FAIL**: \(gate.violations.count) lock and role pairs took locks, listed below."
    }
    return "- **Lock gate**: \(rule). \(enforcement) Today: \(verdict)"
}

private func trendLine(_ trend: Trend) -> String {
    let rule = "a p99.9 or a max more than twice the previous release's and over 100 us above it warns; it never fails"
    guard let previous = trend.previous else {
        return "- **Trend**: \(rule). Skipped: no earlier release carries measurements."
    }
    let verdict = trend.warnings.isEmpty ? "no figure doubled" : "\(trend.warnings.count) warnings, listed below"
    return "- **Trend** against \(previous): \(rule). Today: \(verdict)."
}

private func latencySection(_ report: MeasurementsReport) -> [String] {
    var lines = [
        "## Latency",
        "",
        "From each report's publish (or the Direct lane's IOKit callback) to the loopback satellite's decrypt,"
            + " in the plain build; the reported rep of each scenario, the one whose pad A p99.9 is the median.",
        ""
    ]
    lines += markdownHeader(["run"] + latencyColumns, textColumns: 4)
    lines += report.latency.map { "| \($0.run) " + latencyRow($0.scenario, $0.stream) }
    lines.append("")
    return lines
}

private func lockSection(_ report: MeasurementsReport) -> [String] {
    let entries = report.locks.filter { $0.run == lockStatsRunName }
    var lines = [
        "## Locks by thread role",
        "",
        "The lock-stats build, every scenario's reported rep merged per lock and role: acquisitions summed,"
            + " the worst wait and hold kept.",
        ""
    ]
    lines += markdownHeader(
        ["lock", "role", "acquisitions", "contended", "max wait us", "p99 wait us", "max hold us", "p99 hold us"],
        textColumns: 2
    )
    lines += mergedLockRows(entries).map { row in
        let cells = [
            row.lock, row.role, "\(row.acquisitions)", "\(row.contended)",
            fixed(row.waitMaxUs), fixed(row.waitP99Us), fixed(row.holdMaxUs), fixed(row.holdP99Us)
        ]
        return "| " + cells.joined(separator: " | ") + " |"
    }
    lines.append("")
    return lines
}
