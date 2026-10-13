// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import AppKit
import DishEngine
import XCTest
@testable import Dish

/// The AppKit seams of the app entry: the version the bundle reports and
/// the close-to-background rule.
@MainActor
final class DishAppTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() {
        super.setUp()
        suite = "dish.test.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func testABareBinaryReadsTheZeroVersion() {
        XCTAssertEqual(bundleVersion(Bundle(for: DishAppTests.self)), "0.0.0", "a test bundle carries no strict triple")
    }

    func testClosingTheLastWindowQuitsOnlyWhenBackgroundIsOff() {
        let delegate = DishAppDelegate()
        let background = BackgroundPreferenceStore(defaults: defaults)
        let announcer = RecordingAnnouncer()
        delegate.bind(background: background, announcer: announcer)
        XCTAssertFalse(delegate.applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared), "the default keeps Dish running")
        XCTAssertEqual(announcer.announcements, 1, "the first hide is announced")
        XCTAssertTrue(background.state.noticeShown, "and remembered")
        XCTAssertFalse(delegate.applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared))
        XCTAssertEqual(announcer.announcements, 1, "the second hide is silent")
        background.setRunInBackground(false)
        XCTAssertTrue(delegate.applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared))
        XCTAssertEqual(announcer.announcements, 1, "quitting announces nothing")
    }

    func testTheNoticeIsRememberedAcrossLaunches() {
        let first = DishAppDelegate()
        let announcer = RecordingAnnouncer()
        first.bind(background: BackgroundPreferenceStore(defaults: defaults), announcer: announcer)
        XCTAssertFalse(first.applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared))
        let second = DishAppDelegate()
        second.bind(background: BackgroundPreferenceStore(defaults: defaults), announcer: announcer)
        XCTAssertFalse(second.applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared))
        XCTAssertEqual(announcer.announcements, 1, "a relaunch reads the stored flag")
    }

    func testAnUnboundDelegateQuits() {
        XCTAssertTrue(DishAppDelegate().applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared))
    }
}

/// Counts the announcements instead of posting them.
private final class RecordingAnnouncer: BackgroundAnnouncing {
    private(set) var announcements = 0

    func announce() {
        announcements += 1
    }
}
