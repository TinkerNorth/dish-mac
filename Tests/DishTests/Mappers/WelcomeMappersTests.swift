// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import XCTest
@testable import Dish

/// The welcome's four pages as the desktops word them: the mark on the
/// first, the Satellite download on the third, Back from the second on,
/// Next until the last, which finishes.
final class WelcomeMappersTests: XCTestCase {

    func testTheFirstPageIntroducesDishUnderItsMarkWithNoWayBack() {
        let state = welcomeState(page: 0)
        XCTAssertEqual(state.eyebrow, "Welcome")
        XCTAssertEqual(state.title, "Your controller, on your PC")
        XCTAssertTrue(state.body.hasPrefix("Dish forwards a real game controller plugged into this PC"))
        XCTAssertTrue(state.body.hasSuffix("over your local network. Plug in a pad and it shows up ready to play."), "the sentences join")
        XCTAssertTrue(state.showsMark)
        XCTAssertNil(state.back)
        XCTAssertNil(state.previousPage)
        XCTAssertEqual(state.primary, "Next")
        XCTAssertEqual(state.nextPage, 1)
        XCTAssertEqual(state.skip, "Skip")
        XCTAssertNil(state.download)
    }

    func testTheSecondPageSaysHowItWorksAndGoesBothWays() {
        let state = welcomeState(page: 1)
        XCTAssertEqual(state.eyebrow, "How it works")
        XCTAssertEqual(state.title, "A short hop over Wi-Fi")
        XCTAssertFalse(state.showsMark)
        XCTAssertEqual(state.back, "Back")
        XCTAssertEqual(state.previousPage, 0)
        XCTAssertEqual(state.nextPage, 2)
    }

    func testTheThirdPageOffersTheSatelliteDownload() {
        let state = welcomeState(page: 2)
        XCTAssertEqual(state.eyebrow, "One more thing")
        XCTAssertEqual(state.title, "Install Satellite on the host PC")
        XCTAssertEqual(
            state.download,
            WelcomeLink(title: "Open download page", url: URL(string: "https://dish.tinkernorth.com/downloads/satellite"))
        )
    }

    func testTheLastPageFinishesIntoSetup() {
        let state = welcomeState(page: 3)
        XCTAssertEqual(state.eyebrow, "You’re set")
        XCTAssertEqual(state.title, "Ready when you are")
        XCTAssertEqual(state.primary, "Finish")
        XCTAssertNil(state.nextPage)
        XCTAssertEqual(state.previousPage, 2)
    }

    func testTheDotsLightThePageOnScreenAndMarkThePassedOnes() {
        XCTAssertEqual(welcomeState(page: 2).dots.map(\.phase), [.done, .done, .current, .upcoming])
        XCTAssertEqual(welcomeState(page: 0).dots.map(\.phase), [.current, .upcoming, .upcoming, .upcoming])
    }

    func testAPageOutOfRangeIsClampedToTheFourThereAre() {
        XCTAssertEqual(welcomeState(page: -1).page, 0)
        XCTAssertEqual(welcomeState(page: 9).page, 3)
    }
}
