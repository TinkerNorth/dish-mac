// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Foundation

enum BenchExit {
    static let ok: Int32 = 0
    static let failed: Int32 = 1
    static let usage: Int32 = 2
}

/// Runs the scenarios, prints the tables, writes the files, and answers with
/// the harness's own accounting, never a latency.
@MainActor
func runBench(_ options: BenchOptions) async -> Int32 {
    let timer = SpinCalibration.measure()
    let machine = MachineInfo.current()
    print(banner(options, timer: timer, machine: machine))
    var results: [ScenarioResult] = []
    for scenario in options.scenarios {
        do {
            if scenario.moonlight {
                let run = try await MoonlightScenarioRun.connect(scenario: scenario, options: options, timer: timer)
                await results.append(run.run())
            } else {
                let run = try ScenarioRun(scenario: scenario, options: options, timer: timer)
                await results.append(run.run())
            }
        } catch {
            printError("\(scenario.name) could not start: \(error)")
            return BenchExit.failed
        }
    }
    print(latencyTable(results))
    if lockStatsBuild { print("\n" + lockTable(results)) }
    pacingNotes(results).forEach { print($0) }
    let record = BenchRecord(
        schema: BenchRecord.currentSchema,
        settings: benchSettings(options, timer: timer),
        machine: machine,
        scenarios: results
    )
    do {
        if let json = options.json { try writeJSON(record, to: json) }
        if let csv = options.csv { try writeText(csvRows(results), to: csv) }
    } catch {
        printError("could not write the results: \(error)")
        return BenchExit.failed
    }
    let problems = accountingProblems(results, smoke: options.smoke)
    problems.forEach(printError)
    return problems.isEmpty ? BenchExit.ok : BenchExit.failed
}

func benchSettings(_ options: BenchOptions, timer: TimerCalibration) -> BenchSettings {
    BenchSettings(
        rateHz: options.rateHz,
        secs: options.effectiveSecs,
        reps: options.effectiveReps,
        micHz: options.micHz,
        smoke: options.smoke,
        lockStats: lockStatsBuild,
        spinUs: microseconds(timer.spinNs),
        timerLateP90Us: microseconds(timer.lateP90Ns),
        timeConstrained: timer.timeConstrained,
        scenarios: options.scenarios.map(\.name)
    )
}

func banner(_ options: BenchOptions, timer: TimerCalibration, machine: MachineInfo) -> String {
    let build = lockStatsBuild ? "LOCK_STATS build" : "plain build"
    let length = options.smoke
        ? "smoke: \(fixed(options.effectiveSecs)) s, one rep"
        : "\(fixed(options.secs)) s x \(options.reps) reps after a warm-up"
    let waits = timer.timeConstrained ? "time-constrained waits wake" : "waits (no time constraint granted) wake"
    let first = [
        "DishBench: \(build)", "pad A at \(options.rateHz) Hz", length, "mic \(options.micHz) Hz",
        "\(waits) \(fixed(microseconds(timer.lateP90Ns), digits: 0)) us late at p90",
        "spin window \(fixed(microseconds(timer.spinNs), digits: 0)) us"
    ]
    let second = [
        "Machine: \(machine.cpu)", machine.model, "\(machine.cores) cores", "\(fixed(machine.memoryGB)) GB", machine.os
    ]
    return first.joined(separator: ", ") + "\n" + second.joined(separator: ", ") + "\n"
}
