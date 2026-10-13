// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import XCTest

final class BackgroundModeTests: XCTestCase {

    func testHidingNeedsBothThePreferenceAndAHost() {
        XCTAssertEqual(decideWindowCloseAction(backgroundEnabled: true, trayAvailable: true), .hideToBackground)
        XCTAssertEqual(decideWindowCloseAction(backgroundEnabled: true, trayAvailable: false), .quit)
        XCTAssertEqual(decideWindowCloseAction(backgroundEnabled: false, trayAvailable: true), .quit)
        XCTAssertEqual(decideWindowCloseAction(backgroundEnabled: false, trayAvailable: false), .quit)
    }

    func testTheFirstHideIsAnnouncedOnce() {
        XCTAssertTrue(shouldAnnounceBackground(.hideToBackground, alreadyAnnounced: false))
        XCTAssertFalse(shouldAnnounceBackground(.hideToBackground, alreadyAnnounced: true))
        XCTAssertFalse(shouldAnnounceBackground(.quit, alreadyAnnounced: false))
    }
}
