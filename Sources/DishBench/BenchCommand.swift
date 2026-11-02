// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Foundation

/// What a command line asks for.
enum BenchCommand: Equatable {
    case help
    case bench(BenchOptions)
    case report(ReportOptions)
}

/// The bench's settings; `--smoke` replaces the length and the reps.
struct BenchOptions: Equatable {
    static let smokeSecs = 0.2
    static let warmUpSecs = 0.5
    static let defaultMicHz = 50

    var rateHz = 1000
    var secs = 3.0
    var reps = 3
    var micHz = defaultMicHz
    var json: String?
    var csv: String?
    var smoke = false
    var only: [String] = []

    var effectiveSecs: Double {
        smoke ? Self.smokeSecs : secs
    }

    var effectiveReps: Int {
        smoke ? 1 : reps
    }

    /// The scenarios the run keeps, in their order.
    var scenarios: [BenchScenario] {
        benchScenarios.filter { only.isEmpty || only.contains($0.name) }
    }

    /// Room for every datagram the busiest scenario's longest pass sends,
    /// twice over.
    var arrivalCapacity: Int {
        let perSecond = Double(rateHz + BenchRates.padBHz + BenchRates.directHz * 2 + micHz + BenchRates.rumbleHz)
        return Int((perSecond * max(effectiveSecs, Self.warmUpSecs) * 2).rounded(.up)) + 10000
    }
}

/// A command line the bench cannot run.
struct UsageError: Error, Equatable {
    let message: String
}

let benchUsage = """
Usage: DishBench [--rate HZ] [--secs S] [--reps N] [--mic-hz HZ] [--only S1,S2] [--json PATH] [--csv PATH] [--smoke]
       DishBench report --input-dir DIR --output-dir DIR --version LABEL [--previous-dir DIR] [--commit SHA]
                        [--enforce-lock-gate]

Times each pad's reports from the input processor (or the Direct lane's IOKit
callback) to a loopback satellite's decrypt, with the production objects in
their thread roles. Scenarios S1 to S6; the reported rep of each is the one
whose pad A p99.9 is the median.

  --rate HZ     pad A's report rate (default 1000)
  --secs S      length of each rep (default 3)
  --reps N      reps per scenario after a discarded warm-up (default 3)
  --mic-hz HZ   microphone packets a second in S5 (default 50)
  --only LIST   run only these scenarios, comma-separated
  --json PATH   write the settings, the machine and every rep as JSON
  --csv PATH    write every rep's rows as CSV
  --smoke       0.2 s, one rep, no warm-up; fail on the harness's own accounting
  --help        this text

report merges the bench JSON files in --input-dir into measurements-LABEL.md and
measurements-LABEL.json in --output-dir. It needs a plain and a lock-stats run;
the lock gate (no lock on the Input, HidReader and Receive roles) fails the
report only with --enforce-lock-gate, and the trend against the report in
--previous-dir only ever warns.
"""

func parseCommand(_ arguments: [String]) throws -> BenchCommand {
    if arguments.first == "report" {
        return try .report(parseReport(Array(arguments.dropFirst())))
    }
    var options = BenchOptions()
    var cursor = ArgumentCursor(arguments)
    while let flag = cursor.next() {
        switch flag {
        case "--help", "-h": return .help
        case "--rate": options.rateHz = try cursor.positiveInt(after: flag)
        case "--secs": options.secs = try cursor.positiveDouble(after: flag)
        case "--reps": options.reps = try cursor.positiveInt(after: flag)
        case "--mic-hz": options.micHz = try cursor.positiveInt(after: flag)
        case "--json": options.json = try cursor.value(after: flag)
        case "--csv": options.csv = try cursor.value(after: flag)
        case "--only": options.only = try scenarioNames(cursor.value(after: flag))
        case "--smoke": options.smoke = true
        default: throw UsageError(message: "unknown option \(flag)")
        }
    }
    return .bench(options)
}

private func parseReport(_ arguments: [String]) throws -> ReportOptions {
    var options = ReportOptions()
    var cursor = ArgumentCursor(arguments)
    while let flag = cursor.next() {
        switch flag {
        case "--input-dir": options.inputDir = try cursor.value(after: flag)
        case "--output-dir": options.outputDir = try cursor.value(after: flag)
        case "--version": options.version = try cursor.value(after: flag)
        case "--previous-dir": options.previousDir = try cursor.value(after: flag)
        case "--commit": options.commit = try cursor.value(after: flag)
        case "--enforce-lock-gate": options.enforceLockGate = true
        default: throw UsageError(message: "unknown report option \(flag)")
        }
    }
    guard !options.inputDir.isEmpty, !options.outputDir.isEmpty, !options.version.isEmpty else {
        throw UsageError(message: "report needs --input-dir, --output-dir and --version")
    }
    return options
}

private func scenarioNames(_ list: String) throws -> [String] {
    let names = list.split(separator: ",").map(String.init)
    let known = benchScenarios.map(\.name)
    guard !names.isEmpty, names.allSatisfy(known.contains) else {
        throw UsageError(message: "--only takes scenario names from \(known.joined(separator: ","))")
    }
    return names
}

/// Walks a command line flag by flag.
struct ArgumentCursor {
    private let arguments: [String]
    private var index = 0

    init(_ arguments: [String]) {
        self.arguments = arguments
    }

    mutating func next() -> String? {
        guard index < arguments.count else { return nil }
        let argument = arguments[index]
        index += 1
        return argument
    }

    mutating func value(after flag: String) throws -> String {
        guard let value = next() else { throw UsageError(message: "\(flag) needs a value") }
        return value
    }

    mutating func positiveInt(after flag: String) throws -> Int {
        let text = try value(after: flag)
        guard let number = Int(text), number > 0 else {
            throw UsageError(message: "\(flag) takes a positive whole number, not \(text)")
        }
        return number
    }

    mutating func positiveDouble(after flag: String) throws -> Double {
        let text = try value(after: flag)
        guard let number = Double(text), number.isFinite, number > 0 else {
            throw UsageError(message: "\(flag) takes a positive number, not \(text)")
        }
        return number
    }
}
