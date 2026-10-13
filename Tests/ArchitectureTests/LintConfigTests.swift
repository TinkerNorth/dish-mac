// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import XCTest

/// CONTRIBUTING names the function-length and complexity limits; the lint
/// configuration is where they bite. Knowledge written twice is checked here.
final class LintConfigTests: XCTestCase {

    private var config = ""

    override func setUpWithError() throws {
        config = try RepoFiles.read(".swiftlint.yml")
    }

    private func threshold(_ rule: String, _ level: String) -> Int? {
        guard let ruleRange = config.range(of: "\(rule):\n") else { return nil }
        let block = config[ruleRange.upperBound...].prefix { $0 != "\n" || true }
        let lines = block.split(separator: "\n").prefix(3)
        for line in lines where line.contains("\(level):") {
            return Int(line.split(separator: ":").last?.trimmingCharacters(in: .whitespaces) ?? "")
        }
        return nil
    }

    func testAFunctionLongerThanSixtyLinesFailsTheBuild() {
        XCTAssertEqual(threshold("function_body_length", "warning"), 45)
        XCTAssertEqual(threshold("function_body_length", "error"), 60)
    }

    func testCyclomaticComplexityIsCapped() {
        XCTAssertEqual(threshold("cyclomatic_complexity", "warning"), 10)
        XCTAssertEqual(threshold("cyclomatic_complexity", "error"), 15)
    }

    func testTypeAndFileLengthsAreCapped() {
        XCTAssertEqual(threshold("type_body_length", "error"), 400)
        XCTAssertEqual(threshold("file_length", "error"), 700)
    }

    func testTheTodoRuleIsOn() {
        XCTAssertFalse(config.contains("- todo"), "deferred work goes in Tests/PARITY.md, so the todo rule stays on")
    }

    func testStrictModeIsWhatCIRuns() throws {
        let workflow = try RepoFiles.read(".github/workflows/macos-ci.yml")
        XCTAssertTrue(workflow.contains("swiftlint lint --strict"), "CI must run SwiftLint in strict mode")
        XCTAssertTrue(workflow.contains("swiftformat --lint"), "CI must run SwiftFormat in lint mode")
    }
}
