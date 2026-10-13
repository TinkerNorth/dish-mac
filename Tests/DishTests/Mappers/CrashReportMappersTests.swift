// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishEngine
import XCTest
@testable import Dish

/// The report the user reviews is the log on disk, redacted with this
/// user's home, under the running build.
final class CrashReportMappersTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("dish-report-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    func testTheReportRedactsTheLogUnderTheEnvironmentHeader() throws {
        let log = CrashLog(url: directory.appendingPathComponent("crash.log"))
        try Data("--- dish crash: SIGSEGV\n0 Dish /Users/laura/Dish.app to 192.168.1.9\n".utf8).write(to: log.url)
        let report = crashReportText(log, appVersion: "0.1.0", home: "/Users/laura", system: "Version 26.0 (Build 1)")
        XCTAssertEqual(
            report,
            "Dish 0.1.0\nmacOS Version 26.0 (Build 1)\n\n--- backtrace ---\n--- dish crash: SIGSEGV\n0 Dish ~/Dish.app to [ip]\n"
        )
    }

    func testAMissingLogReportsAnEmptyTrace() {
        let report = crashReportText(
            CrashLog(url: directory.appendingPathComponent("none.log")),
            appVersion: "0.1.0",
            home: "/Users/laura",
            system: "26"
        )
        XCTAssertEqual(report, "Dish 0.1.0\nmacOS 26\n\n--- backtrace ---\n")
    }

    func testTheIssueOpensOnThisRepository() throws {
        let url = try XCTUnwrap(crashIssueURL("Dish 0.1.0\nline"))
        XCTAssertEqual(url.host, "github.com")
        XCTAssertTrue(url.path.hasPrefix("/TinkerNorth/dish-mac/issues/new"))
    }
}
