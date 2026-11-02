// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import XCTest
@testable import DishBench

/// The report merges the bench's runs: it needs a plain and a lock-stats run,
/// holds the Input, HidReader and Receive roles to no lock in every lock-stats
/// run and fails the job on that only when told to enforce it, warns when a
/// figure more than doubles, and writes both files.
final class MeasurementsReportTests: XCTestCase {

    func testAHotRoleTakingALockFailsTheGateWhichIsReportedButNotEnforced() throws {
        let rows = [taken("input.gate", "Input", 3000), taken("routing.table", "Main", 30)]
        let report = try buildReport(runs: [plain(), lockStats(rows)], previous: nil, version: "dev", commit: nil, enforceLockGate: false)
        XCTAssertFalse(report.lockGate.passed)
        XCTAssertFalse(report.lockGate.failsTheJob, "without the flag the gate is only reported")
        XCTAssertEqual(
            report.lockGate.violations,
            [LockViolation(run: "lockstats", scenario: "S1", role: "Input", lock: "input.gate", acquisitions: 3000)]
        )
    }

    func testAnEnforcedGateFailsTheJob() throws {
        let report = try buildReport(
            runs: [plain(), lockStats([taken("satellite.send", "Receive", 7)])],
            previous: nil,
            version: "dev",
            commit: nil,
            enforceLockGate: true
        )
        XCTAssertTrue(report.lockGate.failsTheJob)
    }

    func testLocksOffTheHotRolesPassTheGate() throws {
        let rows = [taken("routing.table", "Main", 30), taken("satellite.send", "Heartbeat", 2)]
        let report = try buildReport(runs: [plain(), lockStats(rows)], previous: nil, version: "dev", commit: nil, enforceLockGate: true)
        XCTAssertTrue(report.lockGate.passed)
        XCTAssertFalse(report.lockGate.failsTheJob)
    }

    func testARunThatRecordedNoLockCannotPass() throws {
        let report = try buildReport(runs: [plain(), lockStats([])], previous: nil, version: "dev", commit: nil, enforceLockGate: false)
        XCTAssertFalse(report.lockGate.sawLocks)
        XCTAssertFalse(report.lockGate.passed, "a gate that saw no lock judged nothing")
    }

    func testTheGateReadsEveryLockStatsRunAndNoPlainOne() throws {
        let runs = [
            plain(rows: [taken("input.gate", "Input", 9)]),
            lockStats([taken("routing.table", "Main", 30)]),
            lockStats([taken("satellite.params", "Receive", 4)], micHz: 1000)
        ]
        let report = try buildReport(runs: runs, previous: nil, version: "dev", commit: nil, enforceLockGate: false)
        XCTAssertEqual(report.lockGate.violations.map(\.run), ["lockstats-mic1000"])
    }

    func testAPlainOrALockStatsRunMissingIsAnError() {
        XCTAssertThrowsError(try buildReport(runs: [lockStats([])], previous: nil, version: "dev", commit: nil, enforceLockGate: false)) {
            XCTAssertEqual($0 as? MissingRunError, MissingRunError(name: "plain"))
        }
        XCTAssertThrowsError(try buildReport(runs: [plain()], previous: nil, version: "dev", commit: nil, enforceLockGate: false)) {
            XCTAssertEqual($0 as? MissingRunError, MissingRunError(name: "lockstats"))
        }
    }

    func testARunIsNamedByItsBuildAndAnyMicrophoneRateButTheDefault() {
        XCTAssertEqual(NamedRun(record(lockStats: false)).name, "plain")
        XCTAssertEqual(NamedRun(record(lockStats: true)).name, "lockstats")
        XCTAssertEqual(NamedRun(record(lockStats: false, micHz: 1000)).name, "plain-mic1000")
    }

    func testAFigureMoreThanTwiceThePreviousAndOver100UsAboveWarns() {
        let warnings = trendWarnings([entry(p999: 250, max: 1500)], previous: [entry(p999: 100, max: 1000)])
        XCTAssertEqual(warnings, [TrendWarning(run: "plain", scenario: "S1", pad: "A", figure: "p99.9", previousUs: 100, currentUs: 250)])
    }

    func testADoublingWithin100UsOrWithNothingToCompareStaysQuiet() {
        XCTAssertEqual(trendWarnings([entry(p999: 90, max: 90)], previous: [entry(p999: 20, max: 20)]), [])
        XCTAssertEqual(trendWarnings([entry(p999: 9000, max: 9000)], previous: []), [])
    }

    func testTheSummaryStatesTheGatesAndCarriesTheTables() throws {
        let report = try buildReport(
            runs: [plain(), lockStats([taken("input.gate", "Input", 3000)])],
            previous: nil,
            version: "before-2.5.0",
            commit: "abc1234",
            enforceLockGate: false
        )
        let markdown = renderReport(report)
        XCTAssertTrue(markdown.hasPrefix("# Dish Mac measurements before-2.5.0\n"))
        XCTAssertTrue(markdown.contains("Commit `abc1234`."))
        XCTAssertTrue(markdown.contains("Reported, not enforced"))
        XCTAssertTrue(markdown.contains("Today: **FAIL**: 1 lock and role pairs took locks"))
        XCTAssertTrue(markdown.contains("Skipped: no earlier release carries measurements."))
        XCTAssertTrue(markdown.contains("| lockstats | S1 | Input | input.gate | 3000 |"))
        XCTAssertTrue(markdown.contains("| plain | S1 | A | Input | 1000 | 3000 |"))
        XCTAssertTrue(markdown.contains("| input.gate | Input | 3000 | 0 |"))
    }

    func testAnnotationsWarnOnATrendAndOnlyNoticeAnUnenforcedGate() throws {
        let previous = try buildReport(
            runs: [plain(p999: 50), lockStats([])],
            previous: nil,
            version: "1.1.0",
            commit: nil,
            enforceLockGate: false
        )
        let report = try buildReport(
            runs: [plain(p999: 400), lockStats([taken("input.gate", "Input", 1)])],
            previous: previous,
            version: "1.2.0",
            commit: nil,
            enforceLockGate: false
        )
        let lines = annotations(report)
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].hasPrefix("::warning title=Trend::plain S1 pad A p99.9 400.0 us, was 50.0 us in 1.1.0"))
        XCTAssertTrue(lines[1].hasPrefix("::notice title=Lock gate::"))
    }

    func testTheReportWritesBothFilesAndFailsOnlyAnEnforcedGate() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dish-measurements-\(UUID().uuidString)")
        let input = directory.appendingPathComponent("raw").path
        let output = directory.appendingPathComponent("out").path
        try FileManager.default.createDirectory(atPath: input, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        try writeJSON(record(lockStats: false), to: input + "/plain.json")
        try writeJSON(record(lockStats: true, rows: [taken("input.gate", "Input", 5)]), to: input + "/lockstats.json")
        var options = ReportOptions(inputDir: input, outputDir: output, version: "dev")
        XCTAssertEqual(runReport(options), BenchExit.ok)
        let json = try Data(contentsOf: URL(fileURLWithPath: output + "/measurements-dev.json"))
        let written = try JSONDecoder().decode(MeasurementsReport.self, from: json)
        XCTAssertEqual(written.version, "dev")
        XCTAssertTrue(FileManager.default.fileExists(atPath: output + "/measurements-dev.md"))
        options.enforceLockGate = true
        XCTAssertEqual(runReport(options), BenchExit.failed)
    }

    // MARK: - Fixtures

    private func plain(p999: Double = 80, rows: [LockRow] = []) -> NamedRun {
        NamedRun(record(lockStats: false, rows: rows, p999: p999))
    }

    private func lockStats(_ rows: [LockRow], micHz: Int = BenchOptions.defaultMicHz) -> NamedRun {
        NamedRun(record(lockStats: true, micHz: micHz, rows: rows))
    }

    private func record(lockStats: Bool, micHz: Int = BenchOptions.defaultMicHz, rows: [LockRow] = [], p999: Double = 80) -> BenchRecord {
        let settings = BenchSettings(
            rateHz: 1000,
            secs: 3,
            reps: 1,
            micHz: micHz,
            smoke: false,
            lockStats: lockStats,
            spinUs: 150,
            timerLateP90Us: 40,
            timeConstrained: true,
            scenarios: ["S1"]
        )
        let rep = RepResult(
            streams: [stream(p999: p999)],
            pacing: [],
            feedback: nil,
            refreshes: 0,
            talliedReports: 0,
            locks: rows,
            nesting: [],
            blocking: []
        )
        return BenchRecord(
            schema: BenchRecord.currentSchema,
            settings: settings,
            machine: MachineInfo(model: "VirtualMac2,1", cpu: "Apple M1 (Virtual)", cores: 3, memoryGB: 7, os: "macOS 26"),
            scenarios: [ScenarioResult(name: "S1", summary: "pad A", reportedRep: 0, reps: [rep])]
        )
    }

    private func stream(p999: Double, max: Double = 99) -> StreamResult {
        StreamResult(
            pad: "A",
            source: "Input",
            rateHz: 1000,
            frames: 3000,
            received: 3000,
            p50Us: 20,
            p99Us: 50,
            p999Us: p999,
            maxUs: max,
            overOneMs: 0,
            longestGapMs: 1.1,
            datagramsPerReport: 1,
            drops: 0
        )
    }

    private func entry(p999: Double, max: Double) -> LatencyEntry {
        LatencyEntry(run: "plain", scenario: "S1", stream: stream(p999: p999, max: max))
    }

    private func taken(_ lock: String, _ role: String, _ acquisitions: UInt64) -> LockRow {
        LockRow(
            lock: lock,
            role: role,
            acquisitions: acquisitions,
            contended: 0,
            waitMaxUs: 0,
            waitP99Us: 0,
            holdMaxUs: 0.5,
            holdP99Us: 0.5
        )
    }
}
