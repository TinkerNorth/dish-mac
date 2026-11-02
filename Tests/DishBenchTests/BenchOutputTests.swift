// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import XCTest
@testable import DishBench

/// What the bench prints and writes: the reported rep's rows, every rep in
/// the CSV, a record that survives JSON, and an exit status that answers the
/// harness's own accounting rather than any latency.
final class BenchOutputTests: XCTestCase {

    func testAStreamResultReadsItsSummaryInMicroseconds() {
        let summary = StreamLatency(sentNs: [0, 1000, 2000, 3000], arrivals: [arrival(0, 40000), arrival(1, 1_501_000)])
        let result = StreamResult(summary, pad: "A", source: "Input", rateHz: 1000, datagrams: 5)
        XCTAssertEqual(result.frames, 4)
        XCTAssertEqual(result.received, 2)
        XCTAssertEqual(result.drops, 2)
        XCTAssertEqual(result.p50Us, 40)
        XCTAssertEqual(result.maxUs, 1500)
        XCTAssertEqual(result.overOneMs, 1)
        XCTAssertEqual(result.longestGapMs, 1.461, accuracy: 0.0005)
        XCTAssertEqual(result.datagramsPerReport, 1.25)
    }

    func testTheTableShowsOnlyTheReportedRep() {
        let table = latencyTable([scenario(reported: 1, p999: [90, 80, 70])])
        let rows = table.split(separator: "\n").dropFirst(2)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first.map(String.init), "| S1 | A | Input | 1000 | 3000 | 20.0 | 50.0 | 80.0 | 99.0 | 0 | 1.100 | 1.00 | 0 |")
    }

    func testTheCsvCarriesEveryRepAndMarksTheReportedOne() {
        let lines = csvRows([scenario(reported: 1, p999: [90, 80, 70])]).split(separator: "\n")
        XCTAssertEqual(lines.count, 4, "the header and three reps")
        XCTAssertTrue(lines[1].hasPrefix("S1,0,0,A,"))
        XCTAssertTrue(lines[2].hasPrefix("S1,1,1,A,"))
    }

    func testARecordSurvivesJson() throws {
        let record = BenchRecord(
            schema: BenchRecord.currentSchema,
            settings: BenchSettings(
                rateHz: 1000,
                secs: 3,
                reps: 3,
                micHz: 50,
                smoke: false,
                lockStats: true,
                spinUs: 1000,
                scenarios: ["S1"]
            ),
            machine: MachineInfo(model: "Mac", cpu: "Apple M1", cores: 3, memoryGB: 7, os: "macOS"),
            scenarios: [scenario(reported: 0, p999: [10])]
        )
        let data = try JSONEncoder().encode(record)
        XCTAssertEqual(try JSONDecoder().decode(BenchRecord.self, from: data), record)
    }

    func testAPadNothingArrivedFromAndSilentFeedbackFailTheAccounting() {
        let empty = scenario(reported: 0, p999: [10], received: 0, rumbleApplied: 0)
        XCTAssertEqual(accountingProblems([empty], smoke: false), [
            "S1: nothing of pad A arrived",
            "S1: no rumble reached the actuators"
        ])
    }

    func testOnlyASmokeRunJudgesThePace() {
        let late = scenario(reported: 0, p999: [10], kept: false)
        XCTAssertEqual(accountingProblems([late], smoke: false), [], "a slow figure is never a failure")
        XCTAssertEqual(accountingProblems([late], smoke: true), ["S1: A at 1000 Hz is off its pace: 0 early, median 1500.0 us late"])
    }

    func testTheLatencyFiguresThemselvesNeverFailTheRun() {
        let slow = scenario(reported: 0, p999: [250_000])
        XCTAssertEqual(accountingProblems([slow], smoke: true), [])
    }

    private func arrival(_ sequence: UInt16, _ ns: UInt64) -> StreamArrival {
        StreamArrival(sequence: sequence, ns: ns)
    }

    private func scenario(
        reported: Int,
        p999: [Double],
        received: Int = 3000,
        rumbleApplied: Int = 100,
        kept: Bool = true
    ) -> ScenarioResult {
        let reps = p999.map { figure in
            RepResult(
                streams: [stream(p999: figure, received: received)],
                pacing: [PacingResult(stream: "A", rateHz: 1000, frames: 3000, early: 0, medianLateUs: kept ? 2 : 1500, kept: kept)],
                feedback: FeedbackResult(rumbleSent: 300, lightbarSent: 30, rumbleApplied: rumbleApplied, lightbarApplied: 30),
                refreshes: 30,
                talliedReports: 3000,
                locks: [],
                nesting: [],
                blocking: []
            )
        }
        return ScenarioResult(name: "S1", summary: "pad A", reportedRep: reported, reps: reps)
    }

    private func stream(p999: Double, received: Int) -> StreamResult {
        StreamResult(
            pad: "A",
            source: "Input",
            rateHz: 1000,
            frames: 3000,
            received: received,
            p50Us: 20,
            p99Us: 50,
            p999Us: p999,
            maxUs: 99,
            overOneMs: 0,
            longestGapMs: 1.1,
            datagramsPerReport: 1,
            drops: 3000 - received
        )
    }
}
