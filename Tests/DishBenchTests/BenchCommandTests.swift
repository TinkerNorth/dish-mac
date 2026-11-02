// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import XCTest
@testable import DishBench

/// The bench's command line: the defaults the brief fixes, each flag, the
/// smoke run's shape, and every line it refuses.
final class BenchCommandTests: XCTestCase {

    func testNoArgumentsRunEveryScenarioAtTheDefaults() throws {
        XCTAssertEqual(try parseCommand([]), .bench(BenchOptions()))
        let options = BenchOptions()
        XCTAssertEqual(options.rateHz, 1000)
        XCTAssertEqual(options.secs, 3)
        XCTAssertEqual(options.reps, 3)
        XCTAssertEqual(options.micHz, 50)
        XCTAssertFalse(options.smoke)
        XCTAssertEqual(options.scenarios.map(\.name), ["S1", "S2", "S3", "S4", "S5", "S6"])
    }

    func testEveryFlagSetsItsOption() throws {
        let arguments = [
            "--rate", "500", "--secs", "1.5", "--reps", "5", "--mic-hz", "1000",
            "--json", "out.json", "--csv", "out.csv", "--only", "S5,S6"
        ]
        var expected = BenchOptions()
        expected.rateHz = 500
        expected.secs = 1.5
        expected.reps = 5
        expected.micHz = 1000
        expected.json = "out.json"
        expected.csv = "out.csv"
        expected.only = ["S5", "S6"]
        XCTAssertEqual(try parseCommand(arguments), .bench(expected))
        XCTAssertEqual(expected.scenarios.map(\.name), ["S5", "S6"])
    }

    func testASmokeRunIsOneShortRepWithoutAWarmUp() throws {
        guard case let .bench(options) = try parseCommand(["--smoke", "--secs", "9", "--reps", "7"]) else {
            return XCTFail("a smoke run is a bench run")
        }
        XCTAssertEqual(options.effectiveSecs, 0.2)
        XCTAssertEqual(options.effectiveReps, 1)
    }

    func testHelpWinsWhereverItIs() throws {
        XCTAssertEqual(try parseCommand(["--rate", "10", "--help"]), .help)
        XCTAssertEqual(try parseCommand(["-h"]), .help)
    }

    func testAnUnknownFlagIsAUsageError() {
        XCTAssertThrowsError(try parseCommand(["--fast"])) { error in
            XCTAssertEqual(error as? UsageError, UsageError(message: "unknown option --fast"))
        }
    }

    func testAMissingValueOrANumberThatIsNotPositiveIsAUsageError() {
        XCTAssertThrowsError(try parseCommand(["--rate"]))
        XCTAssertThrowsError(try parseCommand(["--rate", "0"]))
        XCTAssertThrowsError(try parseCommand(["--rate", "fast"]))
        XCTAssertThrowsError(try parseCommand(["--secs", "-1"]))
        XCTAssertThrowsError(try parseCommand(["--secs", "inf"]))
        XCTAssertThrowsError(try parseCommand(["--only", "S7"]))
        XCTAssertThrowsError(try parseCommand(["--only", ""]))
    }

    func testTheSpinWindowFollowsTheTimerWithinAFloorAndAMillisecond() {
        XCTAssertEqual(SpinCalibration.window(lateP90Ns: 0), 100_000, "the floor")
        XCTAssertEqual(SpinCalibration.window(lateP90Ns: 40000), 140_000, "the 90th percentile and its margin")
        XCTAssertEqual(SpinCalibration.window(lateP90Ns: 8_000_000), 1_000_000, "never past a millisecond")
    }

    func testTheSatelliteHasRoomForTheBusiestPass() {
        var options = BenchOptions()
        options.rateHz = 8000
        options.secs = 10
        let perSecond = 8000 + BenchRates.padBHz + options.micHz
        XCTAssertGreaterThan(options.arrivalCapacity, perSecond * 10)
    }
}
