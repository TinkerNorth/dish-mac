// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import XCTest
@testable import Dish

/// The desktops' Donate page, word for word.
final class SupportMappersTests: XCTestCase {

    func testGitHubSponsorsLeadsAndIsTheOneRecommended() {
        let state = supportPageState()
        XCTAssertEqual(state.options.map(\.name), ["GitHub Sponsors", "Ko-fi", "Buy Me a Coffee"])
        XCTAssertEqual(state.options.map(\.recommended), [true, false, false])
        XCTAssertEqual(state.callToAction, "Sponsor on GitHub Sponsors")
        XCTAssertEqual(state.callToActionURL, URL(string: "https://github.com/sponsors/TinkerNorth"))
    }

    func testEachWayToGiveLinksToItsOwnPage() {
        let urls = supportPageState().options.map(\.url)
        XCTAssertEqual(urls, [
            URL(string: "https://github.com/sponsors/TinkerNorth"),
            URL(string: "https://ko-fi.com/tinkernorth"),
            URL(string: "https://buymeacoffee.com/tinkernorth")
        ])
    }

    func testEachWayToGiveSaysHowOftenAndWithWhat() {
        let options = supportPageState().options
        XCTAssertEqual(options.map(\.cadence), ["Recurring", "One-time", "Either"])
        XCTAssertEqual(
            options.map(\.paysWith),
            ["Card, PayPal, GitHub credit", "Card, Apple Pay, Google Pay, PayPal", "Card, Apple Pay, Google Pay"]
        )
    }
}
