// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import SwiftUI
import XCTest
@testable import Dish

/// The third-party notice as the Licenses page draws it.
final class LicensesMappersTests: XCTestCase {

    private func plain(_ block: LicenseBlock) -> String {
        switch block {
        case let .heading(level, text): "h\(level) " + String(text.characters)
        case let .paragraph(text): "p " + String(text.characters)
        case let .code(text): "code " + text
        case let .row(cells, header): (header ? "th " : "td ") + cells.map { String($0.characters) }.joined(separator: "|")
        case .rule: "rule"
        }
    }

    func testABuildWithoutTheNoticeSaysSo() {
        XCTAssertEqual(
            licensesPageState(notice: nil, appVersion: "1.2.3"),
            .missing(title: "No license manifest", body: "The bundled acknowledgements could not be read from this build.")
        )
        XCTAssertEqual(licensesPageState(notice: "", appVersion: "1.2.3"), licensesPageState(notice: nil, appVersion: "1.2.3"))
    }

    func testTheNoticeEndsOnTheVersionLine() {
        guard case let .notice(blocks, footer) = licensesPageState(notice: "# Notices", appVersion: "1.2.3") else {
            return XCTFail("a notice is drawn")
        }
        XCTAssertEqual(blocks.map { plain($0.block) }, ["h1 Notices"])
        XCTAssertEqual(footer, "Dish 1.2.3 · TinkerNorth · LGPL-3.0")
    }

    func testTheMarkdownBecomesHeadingsParagraphsRulesAndTables() {
        let markdown = """
        # Title

        First line
        and its wrap with a [link](https://example.com).

        ---
        ## 2a. Part

        | Name | SPDX |
        |---|:---:|
        | ENet | `MIT` |
        """
        XCTAssertEqual(licenseBlocks(markdown).map(plain), [
            "h1 Title",
            "p First line and its wrap with a link.",
            "rule",
            "h2 2a. Part",
            "th Name|SPDX",
            "td ENet|MIT"
        ])
    }

    func testALicenceTextIsKeptVerbatimInsideItsFence() {
        let markdown = "Intro\n```\nCopyright (c) 2002\n\n  Permission *granted*\n```\nAfter"
        XCTAssertEqual(licenseBlocks(markdown).map(plain), ["p Intro", "code Copyright (c) 2002\n\n  Permission *granted*", "p After"])
    }

    func testAnUnclosedFenceStillShowsItsText() {
        XCTAssertEqual(licenseBlocks("```\nlast words").map(plain), ["code last words"])
    }

    func testALinkStaysLive() {
        let text = inlineMarkdown("see [the site](https://example.com)")
        XCTAssertEqual(text.runs.compactMap(\.link), [URL(string: "https://example.com")])
    }

    func testTheShippedNoticeParses() throws {
        let notice = try XCTUnwrap(thirdPartyNotice(in: Bundle.module), "THIRD_PARTY.md ships in the resource bundle")
        let blocks = licenseBlocks(notice)
        XCTAssertEqual(blocks.first.map(plain), "h1 Third-party notices")
        XCTAssertGreaterThanOrEqual(blocks.filter { if case .code = $0 { true } else { false } }.count, 3, "each licence text stays whole")
    }

    func testATopHeadingIsATitleAndATablesHeaderStandsOut() {
        XCTAssertEqual(licenseHeadingFont(1), DishFont.title)
        XCTAssertEqual(licenseHeadingFont(2), DishFont.body)
        XCTAssertEqual(licenseCellFont(header: true), DishFont.control)
        XCTAssertEqual(licenseCellFont(header: false), DishFont.caption)
        XCTAssertEqual(licenseCellColor(header: true), DishTheme.onSurface)
        XCTAssertEqual(licenseCellColor(header: false), DishTheme.muted)
    }
}
