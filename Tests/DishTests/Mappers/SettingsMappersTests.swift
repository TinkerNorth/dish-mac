// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import DishEngine
import XCTest
@testable import Dish

/// Which of Settings' conditional rows show.
final class SettingsMappersTests: XCTestCase {

    private func state(
        mode: KeepAwakeMode = .whileControllerActive,
        uploadPossible: Bool = true,
        crashLog: Bool = false
    ) -> SettingsPageState {
        settingsPageState(
            keepAwake: KeepAwakePreferences(mode: mode),
            uploadPossible: uploadPossible,
            facts: ShellFacts(update: UpdateStatus(currentVersion: "1.2.3"), crashLogPresent: crashLog)
        )
    }

    func testTheStillnessStepperShowsOnlyWhileKeepAwakeWaitsOnAUsedPad() {
        XCTAssertTrue(state(mode: .whileControllerActive).showsIdleTimeout)
        XCTAssertFalse(state(mode: .whileConnected).showsIdleTimeout)
        XCTAssertFalse(state(mode: .off).showsIdleTimeout)
    }

    func testTheDisplaySwitchShowsWhileKeepAwakeHoldsAnything() {
        XCTAssertTrue(state(mode: .whileControllerActive).showsDisplayAwake)
        XCTAssertTrue(state(mode: .whileConnected).showsDisplayAwake)
        XCTAssertFalse(state(mode: .off).showsDisplayAwake)
    }

    func testABuildWithNoReportingAddressSaysTheSwitchSendsNothing() {
        XCTAssertTrue(state(uploadPossible: false).showsUploadImpossible)
        XCTAssertFalse(state(uploadPossible: true).showsUploadImpossible)
    }

    func testTheCrashReportRowShowsWhileALogWaits() {
        XCTAssertTrue(state(crashLog: true).showsCrashReport)
        XCTAssertFalse(state(crashLog: false).showsCrashReport)
    }

    func testAboutEndsOnTheVersionLine() {
        XCTAssertEqual(state().aboutLine, "Dish 1.2.3 · TinkerNorth · LGPL-3.0")
    }
}
