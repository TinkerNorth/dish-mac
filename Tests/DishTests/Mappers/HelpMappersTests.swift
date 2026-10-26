// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import XCTest
@testable import Dish

/// Help & FAQ as the desktops have it: the sections in their order, every
/// question with its answer whole, the walk-through and the two links.
final class HelpMappersTests: XCTestCase {

    private let state = helpPageState()

    func testTheSectionsAreTheDesktopsInTheirOrder() {
        XCTAssertEqual(state.sections.map(\.title), ["CONCEPTS", "BEST PERFORMANCE", "TROUBLESHOOTING", "ABOUT DISH"])
        XCTAssertEqual(state.sections.map(\.entries.count), [3, 2, 4, 2])
        XCTAssertEqual(state.linksTitle, "LINKS")
    }

    func testEveryQuestionHasItsAnswer() {
        let entries = state.sections.flatMap(\.entries)
        XCTAssertEqual(entries.first?.question, "What is Dish?")
        XCTAssertEqual(Set(entries.map(\.question)).count, entries.count, "no question twice")
        XCTAssertFalse(entries.contains { $0.answer.isEmpty })
    }

    func testAnAnswerSplitAcrossKeysReadsAsOneParagraph() {
        let latency = state.sections[1].entries[0]
        XCTAssertEqual(latency.question, "What’s the best setup for low latency?")
        XCTAssertEqual(
            latency.answer,
            "Both PCs on the same router, wired Ethernet where you can, 5 GHz Wi-Fi otherwise. Dish needs this PC and the host PC on the "
                + "same local network — it sends input as small UDP packets, so a fast LAN keeps the delay tiny."
        )
        let motion = state.sections[2].entries[3].answer
        XCTAssertTrue(motion.contains("(DualSense, DualShock 4, Switch Pro), and a PlayStation-style controller type on the slot."))
    }

    func testTheWalkThroughAndTheLinks() {
        XCTAssertEqual(state.walkThrough, "Walk me through setup")
        XCTAssertEqual(state.links.map(\.title), ["Privacy policy", "View source on GitHub"])
        XCTAssertEqual(state.links.map(\.url), [URL(string: DishLinks.privacy), URL(string: "https://github.com/TinkerNorth")])
    }
}
