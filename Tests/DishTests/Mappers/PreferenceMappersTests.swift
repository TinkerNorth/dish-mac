// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import DishEngine
import SwiftUI
import XCTest
@testable import Dish

final class PreferenceMappersTests: XCTestCase {

    func testEveryThemeModeHasItsSchemeAndWord() {
        XCTAssertNil(colorScheme(for: .system))
        XCTAssertEqual(colorScheme(for: .light), .light)
        XCTAssertEqual(colorScheme(for: .dark), .dark)
        XCTAssertEqual(themeModeText(.system), "System")
        XCTAssertEqual(themeModeText(.light), "Light")
        XCTAssertEqual(themeModeText(.dark), "Dark")
    }

    func testEveryKeepAwakeModeHasItsWord() {
        XCTAssertEqual(keepAwakeModeText(.off), "Off")
        XCTAssertEqual(keepAwakeModeText(.whileControllerActive), "While playing")
        XCTAssertEqual(keepAwakeModeText(.whileConnected), "While connected")
        XCTAssertEqual(idleTimeoutText(5), "5 min")
    }

    func testThePowerSectionSaysTheLidStillSleepsTheMac() {
        XCTAssertEqual(
            L10n.app.lidStillSleepsTheMac,
            "Closing the lid still puts the Mac to sleep unless a display and power are connected."
        )
    }

    func testTheUpdateStatusLineForEveryPhase() {
        var status = UpdateStatus(phase: .idle, currentVersion: "0.1.0")
        let never = UpdateCheckTime(lastCheckMs: 0, nowMs: 1_700_000_000_000)
        XCTAssertEqual(updateStatusText(status, time: never), "No update information yet.")
        let checked = UpdateCheckTime(lastCheckMs: 1_699_990_000_000, nowMs: 1_700_000_000_000)
        XCTAssertTrue(updateStatusText(status, time: checked).hasPrefix("Dish 0.1.0 · last checked "))
        status.phase = .disabled
        XCTAssertEqual(updateStatusText(status, time: never), "Automatic update checks are off.")
        status.phase = .checking
        XCTAssertEqual(updateStatusText(status, time: never), "Checking for updates…")
        status.phase = .upToDate
        XCTAssertEqual(updateStatusText(status, time: never), "You're on the latest version.")
        status.phase = .available
        status.availableVersion = "0.2.0"
        XCTAssertEqual(updateStatusText(status, time: never), "Dish 0.2.0 is available.")
    }

    func testEveryFailureHasItsLine() {
        XCTAssertEqual(updateFailureText(.offline), "You're offline. Dish will retry automatically.")
        XCTAssertEqual(updateFailureText(.manifestInvalid), "The release information didn't parse. Dish will retry automatically.")
        XCTAssertEqual(updateFailureText(.http), "The update check failed. Dish will retry automatically.")
        XCTAssertEqual(updateFailureText(.none), "The update check failed. Dish will retry automatically.")
    }

    func testTheLastCheckReadsRelativeToTheClock() {
        XCTAssertEqual(lastCheckText(UpdateCheckTime(lastCheckMs: 0, nowMs: 1_700_000_000_000)), "never")
        XCTAssertEqual(lastCheckText(UpdateCheckTime(lastCheckMs: 1_699_996_400_000, nowMs: 1_700_000_000_000)), "1 hour ago")
    }

    func testTheLastCheckTicksWithTheClockAlone() {
        let checked = UpdateCheckTime(lastCheckMs: 1_700_000_000_000, nowMs: 1_700_000_120_000)
        var later = checked
        later.nowMs += 60000
        XCTAssertEqual(lastCheckText(checked), "2 minutes ago")
        XCTAssertEqual(lastCheckText(later), "3 minutes ago")
    }

    func testCheckForUpdatesWaitsWhileACheckRunsOrChecksAreOff() {
        XCTAssertFalse(updateCheckAllowed(.checking))
        XCTAssertFalse(updateCheckAllowed(.disabled))
        for phase in [UpdatePhase.idle, .upToDate, .available, .failed] {
            XCTAssertTrue(updateCheckAllowed(phase), "\(phase)")
        }
    }

    func testTheReleasePageShowsOnlyWithAnAvailableLink() {
        var status = UpdateStatus(phase: .available, currentVersion: "0.1.0")
        XCTAssertFalse(showsReleasePage(status), "no link")
        status.notesUrl = "https://github.com/TinkerNorth/dish-mac/releases/tag/0.2.0"
        XCTAssertTrue(showsReleasePage(status))
        status.phase = .upToDate
        XCTAssertFalse(showsReleasePage(status))
    }
}
