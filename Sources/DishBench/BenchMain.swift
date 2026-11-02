// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Foundation

/// `DishBench`: the frame-path bench, and with `report` its measurements report.
@main
enum BenchMain {
    static func main() async {
        let status = await run(Array(CommandLine.arguments.dropFirst()))
        exit(status)
    }

    @MainActor
    static func run(_ arguments: [String]) async -> Int32 {
        let command: BenchCommand
        do {
            command = try parseCommand(arguments)
        } catch {
            let message = (error as? UsageError)?.message ?? "\(error)"
            printError(message + "\n\n" + benchUsage)
            return BenchExit.usage
        }
        switch command {
        case .help:
            print(benchUsage)
            return BenchExit.ok
        case let .bench(options):
            return await runBench(options)
        case let .report(options):
            return runReport(options)
        }
    }
}
