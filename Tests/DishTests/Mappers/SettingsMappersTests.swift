// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import DishEngine
import XCTest
@testable import Dish

/// What Settings draws: every control's value from the model's facts, which
/// of the conditional rows show, the update row and the version line.
final class SettingsMappersTests: XCTestCase {

    private func facts(
        mode: KeepAwakeMode = .whileControllerActive,
        uploadPossible: Bool = true,
        crashLog: Bool = false
    ) -> ShellFacts {
        var facts = ShellFacts(update: UpdateStatus(currentVersion: "1.2.3"), crashLogPresent: crashLog)
        facts.preferences = PreferenceFacts(keepAwake: KeepAwakePreferences(mode: mode), crashUploadPossible: uploadPossible)
        return facts
    }

    private func state(
        mode: KeepAwakeMode = .whileControllerActive,
        uploadPossible: Bool = true,
        crashLog: Bool = false
    ) -> SettingsPageState {
        settingsPageState(facts: facts(mode: mode, uploadPossible: uploadPossible, crashLog: crashLog))
    }

    func testEveryControlReadsItsPreference() {
        var facts = facts()
        facts.forwarding = ForwardingFlags(motion: false, touchpad: true, rumble: false)
        facts.preferences.theme = .dark
        facts.preferences.lightbar = .off
        facts.preferences.runInBackground = false
        facts.preferences.keepAwake = KeepAwakePreferences(mode: .whileConnected, idleTimeoutMinutes: 7, keepDisplayAwake: true)
        facts.preferences.crashReportsShared = false
        facts.preferences.updateChecksEnabled = false
        let state = settingsPageState(facts: facts)
        XCTAssertEqual(state.theme, .dark)
        XCTAssertEqual([state.rumble, state.touchpad, state.motion], [false, true, false])
        XCTAssertEqual(state.lightbar, .off)
        XCTAssertFalse(state.runInBackground)
        XCTAssertEqual(state.keepAwake, KeepAwakePreferences(mode: .whileConnected, idleTimeoutMinutes: 7, keepDisplayAwake: true))
        XCTAssertFalse(state.crashReportsShared)
        XCTAssertFalse(state.updateChecksEnabled)
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

    func testTheUpdateRowWordsTheLastCheckOnTheEnginesClock() {
        var facts = facts()
        facts.updateClock = UpdateCheckTime(lastCheckMs: 1_700_000_000_000, nowMs: 1_700_000_300_000)
        let row = settingsPageState(facts: facts).update
        XCTAssertEqual(row.status, "Dish 1.2.3 · last checked 5 minutes ago")
        XCTAssertEqual(row.statusColor, DishTheme.onSurface)
        XCTAssertTrue(row.canCheck)
        XCTAssertNil(row.releasePage)
        XCTAssertFalse(row.offersSkip)
    }

    func testAnAvailableUpdateOffersItsPageAndASkip() throws {
        var status = UpdateStatus(phase: .available, currentVersion: "1.2.3")
        status.availableVersion = "1.3.0"
        status.notesUrl = "https://github.com/TinkerNorth/dish-mac/releases/tag/1.3.0"
        let row = updateRow(status, time: UpdateCheckTime())
        XCTAssertEqual(try XCTUnwrap(row.releasePage).absoluteString, status.notesUrl)
        XCTAssertTrue(row.offersSkip)
    }

    func testARequiredUpdateIsInTheErrorToneAndCannotBeSkipped() {
        var status = UpdateStatus(phase: .available, currentVersion: "1.2.3")
        status.notesUrl = "https://github.com/TinkerNorth/dish-mac/releases/tag/2.0.0"
        status.required = true
        let row = updateRow(status, time: UpdateCheckTime())
        XCTAssertEqual(row.statusColor, DishTheme.error)
        XCTAssertNotNil(row.releasePage)
        XCTAssertFalse(row.offersSkip)
    }

    func testCheckForUpdatesWaitsWhileACheckRuns() {
        let row = updateRow(UpdateStatus(phase: .checking, currentVersion: "1.2.3"), time: UpdateCheckTime())
        XCTAssertFalse(row.canCheck)
    }
}
