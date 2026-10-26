// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import DishEngine
import XCTest
@testable import Dish

/// The report the user reviews is the log as the model last read it,
/// redacted with this user's home, under the running build.
final class CrashReportMappersTests: XCTestCase {

    func testTheReportRedactsTheLogUnderTheEnvironmentHeader() {
        let report = crashReportText(
            "--- dish crash: SIGSEGV\n0 Dish /Users/laura/Dish.app to 192.168.1.9\n",
            appVersion: "0.1.0",
            home: "/Users/laura",
            system: "Version 26.0 (Build 1)"
        )
        XCTAssertEqual(
            report,
            "Dish 0.1.0\nmacOS Version 26.0 (Build 1)\n\n--- backtrace ---\n--- dish crash: SIGSEGV\n0 Dish ~/Dish.app to [ip]\n"
        )
    }

    func testAMissingLogReportsAnEmptyTrace() {
        let report = crashReportText("", appVersion: "0.1.0", home: "/Users/laura", system: "26")
        XCTAssertEqual(report, "Dish 0.1.0\nmacOS 26\n\n--- backtrace ---\n")
    }

    func testThePageReadsTheLogTheModelLastReadUnderTheRunningVersion() throws {
        var facts = ShellFacts(update: UpdateStatus(currentVersion: "0.2.0"), crashLogPresent: true)
        facts.crashLogText = "--- dish crash: SIGABRT\n"
        let state = crashReportPageState(facts: facts, home: "/Users/laura", system: "26")
        XCTAssertEqual(state.report, "Dish 0.2.0\nmacOS 26\n\n--- backtrace ---\n--- dish crash: SIGABRT\n")
        XCTAssertEqual(try XCTUnwrap(state.issueURL).host, "github.com")
    }

    func testTheIssueOpensOnThisRepository() throws {
        let url = try XCTUnwrap(crashIssueURL("Dish 0.1.0\nline"))
        XCTAssertEqual(url.host, "github.com")
        XCTAssertTrue(url.path.hasPrefix("/TinkerNorth/dish-mac/issues/new"))
    }
}
