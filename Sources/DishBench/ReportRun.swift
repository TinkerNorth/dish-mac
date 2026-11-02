// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Foundation

/// The report's inputs and outputs.
struct ReportOptions: Equatable {
    var inputDir = ""
    var outputDir = ""
    var version = ""
    var previousDir: String?
    var commit: String?
    var enforceLockGate = false
}

/// Two runs the report would have to tell apart by name alone.
struct DuplicateRunError: Error, Equatable, CustomStringConvertible {
    let name: String

    var description: String {
        "two \(name) runs in the input directory"
    }
}

/// Reads every bench JSON in the input directory, writes
/// `measurements-<version>.md` and `.json`, prints the gates as workflow
/// annotations, and fails only on a missing run or an enforced gate.
func runReport(_ options: ReportOptions) -> Int32 {
    do {
        let runs = try loadRuns(from: options.inputDir)
        let previous = loadPreviousReport(from: options.previousDir)
        let report = try buildReport(
            runs: runs,
            previous: previous,
            version: options.version,
            commit: options.commit,
            enforceLockGate: options.enforceLockGate
        )
        try FileManager.default.createDirectory(atPath: options.outputDir, withIntermediateDirectories: true)
        let base = URL(fileURLWithPath: options.outputDir).appendingPathComponent("measurements-\(options.version)").path
        try writeJSON(report, to: base + ".json")
        try writeText(renderReport(report), to: base + ".md")
        annotations(report).forEach { print($0) }
        return report.lockGate.failsTheJob ? BenchExit.failed : BenchExit.ok
    } catch {
        print("::error title=Measurements report::\(error)")
        return BenchExit.failed
    }
}

/// Each bench record in `directory`, named by its build and microphone rate.
func loadRuns(from directory: String) throws -> [NamedRun] {
    let decoder = JSONDecoder()
    let runs = try jsonFiles(in: directory).map { file in
        try NamedRun(decoder.decode(BenchRecord.self, from: Data(contentsOf: file)))
    }
    let names = runs.map(\.name)
    if let repeated = names.first(where: { name in names.filter { $0 == name }.count > 1 }) {
        throw DuplicateRunError(name: repeated)
    }
    return runs
}

/// The previous release's report, when one was downloaded and reads as one.
func loadPreviousReport(from directory: String?) -> MeasurementsReport? {
    guard let directory, let files = try? jsonFiles(in: directory) else { return nil }
    let reports = files.filter { $0.lastPathComponent.hasPrefix("measurements-") }
    guard let file = reports.first, let data = try? Data(contentsOf: file) else { return nil }
    return try? JSONDecoder().decode(MeasurementsReport.self, from: data)
}

private func jsonFiles(in directory: String) throws -> [URL] {
    let url = URL(fileURLWithPath: directory)
    let names = try FileManager.default.contentsOfDirectory(atPath: directory)
    return names.filter { $0.hasSuffix(".json") }.sorted().map { url.appendingPathComponent($0) }
}

/// The gates as GitHub annotations: a trend is a warning, the unenforced lock
/// gate a notice, the enforced one an error.
func annotations(_ report: MeasurementsReport) -> [String] {
    let previous = report.trend.previous ?? "the previous release"
    let trend = report.trend.warnings.map { warning in
        let figure = "\(warning.run) \(warning.scenario) pad \(warning.pad) \(warning.figure)"
        let change = "\(fixed(warning.currentUs)) us, was \(fixed(warning.previousUs)) us in \(previous)"
        return "::warning title=Trend::\(figure) \(change)"
    }
    guard !report.lockGate.passed else { return trend }
    let count = report.lockGate.violations.count
    let summary = report.lockGate.sawLocks
        ? "\(count) lock and role pairs on the Input, HidReader and Receive roles"
        : "the lock-stats runs recorded no lock at all"
    let level = report.lockGate.enforced ? "error" : "notice"
    let note = report.lockGate.enforced ? "" : " (reported, not enforced until the optimisation PR)"
    return trend + ["::\(level) title=Lock gate::\(summary)\(note)"]
}
