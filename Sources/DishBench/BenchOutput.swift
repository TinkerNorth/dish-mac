// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Foundation

/// A pacer judged on fewer frames than this says nothing about its pace.
let minimumJudgedFrames = 8

func fixed(_ value: Double, digits: Int = 1) -> String {
    String(format: "%.\(digits)f", value)
}

let latencyColumns = [
    "scenario", "pad", "source", "rate Hz", "frames", "p50 us", "p99 us", "p99.9 us", "max us", "over 1 ms", "longest gap ms",
    "datagrams/report", "drops"
]

let latencyHeader = markdownHeader(latencyColumns, textColumns: 3)

let lockHeader = markdownHeader(
    ["scenario", "lock", "role", "acquisitions", "contended", "max wait us", "p99 wait us", "max hold us", "p99 hold us"],
    textColumns: 3
)

/// A table's header and its rule: the first `textColumns` left-aligned, the
/// figures right-aligned.
func markdownHeader(_ columns: [String], textColumns: Int) -> [String] {
    let names = "| " + columns.joined(separator: " | ") + " |"
    let rule = "| " + columns.indices.map { $0 < textColumns ? "---" : "---:" }.joined(separator: " | ") + " |"
    return [names, rule]
}

private let csvColumns = [
    "scenario", "rep", "reported", "pad", "source", "rateHz", "frames", "received", "p50Us", "p99Us", "p999Us", "maxUs",
    "overOneMs", "longestGapMs", "datagramsPerReport", "drops"
]

func latencyRow(_ scenario: String, _ stream: StreamResult) -> String {
    let cells = [
        scenario, stream.pad, stream.source, "\(stream.rateHz)", "\(stream.frames)",
        fixed(stream.p50Us), fixed(stream.p99Us), fixed(stream.p999Us), fixed(stream.maxUs),
        "\(stream.overOneMs)", fixed(stream.longestGapMs, digits: 3), fixed(stream.datagramsPerReport, digits: 2), "\(stream.drops)"
    ]
    return "| " + cells.joined(separator: " | ") + " |"
}

func lockRow(_ scenario: String, _ row: LockRow) -> String {
    let cells = [
        scenario, row.lock, row.role, "\(row.acquisitions)", "\(row.contended)",
        fixed(row.waitMaxUs), fixed(row.waitP99Us), fixed(row.holdMaxUs), fixed(row.holdP99Us)
    ]
    return "| " + cells.joined(separator: " | ") + " |"
}

/// The reported rep of every scenario, one row per pad.
func latencyTable(_ results: [ScenarioResult]) -> String {
    let rows = results.flatMap { scenario in
        (scenario.reported?.streams ?? []).map { latencyRow(scenario.name, $0) }
    }
    return (latencyHeader + rows).joined(separator: "\n")
}

/// The reported rep of every scenario, one row per lock and role that took it.
func lockTable(_ results: [ScenarioResult]) -> String {
    let rows = results.flatMap { scenario in
        (scenario.reported?.locks ?? []).map { lockRow(scenario.name, $0) }
    }
    return (lockHeader + rows).joined(separator: "\n")
}

/// Every rep's rows; `reported` marks the rep the table shows.
func csvRows(_ results: [ScenarioResult]) -> String {
    var lines = [csvColumns.joined(separator: ",")]
    for scenario in results {
        for (rep, result) in scenario.reps.enumerated() {
            for stream in result.streams {
                let cells = [
                    scenario.name, "\(rep)", rep == scenario.reportedRep ? "1" : "0", stream.pad, stream.source,
                    "\(stream.rateHz)", "\(stream.frames)", "\(stream.received)", fixed(stream.p50Us), fixed(stream.p99Us),
                    fixed(stream.p999Us), fixed(stream.maxUs), "\(stream.overOneMs)", fixed(stream.longestGapMs, digits: 3),
                    fixed(stream.datagramsPerReport, digits: 3), "\(stream.drops)"
                ]
                lines.append(cells.joined(separator: ","))
            }
        }
    }
    return lines.joined(separator: "\n") + "\n"
}

func writeJSON(_ value: some Encodable, to path: String) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(value).write(to: URL(fileURLWithPath: path))
}

func writeText(_ text: String, to path: String) throws {
    try Data(text.utf8).write(to: URL(fileURLWithPath: path))
}

func printError(_ text: String) {
    FileHandle.standardError.write(Data((text + "\n").utf8))
}

/// What the harness's own accounting found wrong, never a latency: a pad
/// nothing of arrived from, a feedback scenario whose commands never reached
/// the actuators, and in a smoke run a pacer that sent a frame before its
/// deadline, which means it was not applied. How late a pacer ran is the
/// runner's timer and load: `pacingNotes` prints it and nothing fails on it.
func accountingProblems(_ results: [ScenarioResult], smoke: Bool) -> [String] {
    var problems: [String] = []
    for scenario in results {
        guard let rep = scenario.reported else {
            problems.append("\(scenario.name): no rep ran")
            continue
        }
        for stream in rep.streams where stream.received == 0 {
            problems.append("\(scenario.name): nothing of pad \(stream.pad) arrived")
        }
        if let feedback = rep.feedback, feedback.rumbleApplied == 0 {
            problems.append("\(scenario.name): no rumble reached the actuators")
        }
        guard smoke else { continue }
        for pacing in rep.pacing where pacing.early > 0 {
            problems.append("\(scenario.name): \(pacing.stream) at \(pacing.rateHz) Hz sent \(pacing.early) frames before their deadlines")
        }
    }
    return problems
}

/// The pacers whose median frame left more than a millisecond after its
/// deadline, judged on eight frames or more.
func pacingNotes(_ results: [ScenarioResult]) -> [String] {
    results.flatMap { scenario in
        (scenario.reported?.pacing ?? []).filter { $0.frames >= minimumJudgedFrames && !$0.kept }.map { pacing in
            let stream = "\(scenario.name) \(pacing.stream) at \(pacing.rateHz) Hz"
            return "note: \(stream) ran a median \(fixed(pacing.medianLateUs)) us behind its deadlines"
        }
    }
}
