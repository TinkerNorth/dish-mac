// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import XCTest
@testable import DishCore

/// The scrub happens before the user ever sees the text, and the issue URL
/// never grows past what a browser carries.
final class CrashReportTests: XCTestCase {

    func testTheHomeDirectoryCollapsesToATilde() {
        let raw = "0 Dish 0x1 /Users/laura/Library/Logs/Dish/crash.log"
        XCTAssertEqual(CrashReport.redact(raw, home: "/Users/laura"), "0 Dish 0x1 ~/Library/Logs/Dish/crash.log")
        XCTAssertEqual(CrashReport.redact(raw, home: ""), raw, "no home, nothing to collapse")
        XCTAssertEqual(CrashReport.redact(raw, home: "/"), raw, "the root would eat every slash")
    }

    func testKeyShapedHexRunsAreRedacted() {
        let key = String(repeating: "ab", count: 32)
        XCTAssertEqual(CrashReport.redact("key=\(key) done", home: ""), "key=[redacted] done")
        XCTAssertEqual(CrashReport.redact("addr 0x1f3a9c", home: ""), "addr 0x1f3a9c", "a short address is not a key")
    }

    func testAddressesAndLocalNamesAreRedacted() {
        XCTAssertEqual(CrashReport.redact("to 192.168.1.42:9443", home: ""), "to [ip]:9443")
        XCTAssertEqual(CrashReport.redact("Lauras-MacBook-Pro.local", home: ""), "[host].local")
        XCTAssertEqual(CrashReport.redact("Dish 0.1.0", home: ""), "Dish 0.1.0", "a version is not an address")
    }

    func testTheReportLeadsWithTheEnvironmentThenTheRedactedTrace() {
        let report = CrashReport.build(
            rawLog: "--- dish crash: SIGSEGV\n/Users/me/x",
            home: "/Users/me",
            appVersion: "0.1.0",
            system: "26.0"
        )
        XCTAssertEqual(report, "Dish 0.1.0\nmacOS 26.0\n\n--- backtrace ---\n--- dish crash: SIGSEGV\n~/x")
    }

    func testTheIssueURLCarriesTheTitleAndTheBody() throws {
        let url = try XCTUnwrap(CrashReport.issueURL(for: "Dish 0.1.0\nline"))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.host, "github.com")
        XCTAssertEqual(components.path, "/TinkerNorth/dish-mac/issues/new")
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(items["title"], "Crash report")
        XCTAssertEqual(items["body"], "Dish 0.1.0\nline")
    }

    func testAnOversizeReportIsHalvedUntilTheURLFitsAndSaysSo() throws {
        let huge = String(repeating: "frame 0x0000000100003f2c Dish 0 + 16172\n", count: 400)
        let url = try XCTUnwrap(CrashReport.issueURL(for: huge))
        XCTAssertLessThanOrEqual(url.absoluteString.utf8.count, CrashReport.maxIssueURLBytes)
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let body = try XCTUnwrap(components.queryItems?.first { $0.name == "body" }?.value)
        XCTAssertTrue(body.hasSuffix(CrashReport.truncationNotice), "the user learns the file is the real artifact")
        XCTAssertTrue(huge.hasPrefix(body.dropLast(CrashReport.truncationNotice.count)), "the head of the report survives")
    }
}
