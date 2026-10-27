// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Combine
import DishCore
import XCTest
@testable import DishEngine

/// Each scalar preference store: the fleet's keys, lenient reads, idempotent
/// writes that persist and republish once.
@MainActor
final class PreferenceStoresTests: XCTestCase {

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

    private func emissions<S: Equatable>(_ publisher: AnyPublisher<S, Never>, _ bag: inout Set<AnyCancellable>) -> () -> [S] {
        var seen: [S] = []
        publisher.dropFirst().sink { seen.append($0) }.store(in: &bag)
        return { seen }
    }

    // MARK: - Theme

    func testThemeDefaultsToSystemAndReadsTheFleetsToken() {
        XCTAssertEqual(ThemePreferenceStore(defaults: defaults).state, .system)
        defaults.set("dark", forKey: "theme_mode")
        XCTAssertEqual(ThemePreferenceStore(defaults: defaults).state, .dark)
        defaults.set("sepia", forKey: "theme_mode")
        XCTAssertEqual(ThemePreferenceStore(defaults: defaults).state, .system, "an unknown token reads as the default")
    }

    func testSettingTheThemePersistsAndEmitsOnce() {
        let store = ThemePreferenceStore(defaults: defaults)
        var bag = Set<AnyCancellable>()
        let seen = emissions(store.statePublisher, &bag)
        store.setMode(.light)
        store.setMode(.light)
        XCTAssertEqual(seen(), [.light])
        XCTAssertEqual(defaults.string(forKey: "theme_mode"), "light")
    }

    // MARK: - Background

    func testBackgroundDefaultsToRunningWithNoNotice() {
        XCTAssertEqual(
            BackgroundPreferenceStore(defaults: defaults).state,
            BackgroundPreferences(runInBackground: true, noticeShown: false)
        )
    }

    func testBackgroundWritesPersistAndAreIdempotent() {
        let store = BackgroundPreferenceStore(defaults: defaults)
        var bag = Set<AnyCancellable>()
        let seen = emissions(store.statePublisher, &bag)
        store.setRunInBackground(false)
        store.setRunInBackground(false)
        store.setNoticeShown(true)
        XCTAssertEqual(seen().count, 2)
        XCTAssertEqual(defaults.bool(forKey: "background_run_enabled"), false)
        XCTAssertEqual(defaults.bool(forKey: "background_notice_shown"), true)
        XCTAssertEqual(
            BackgroundPreferenceStore(defaults: defaults).state,
            BackgroundPreferences(runInBackground: false, noticeShown: true)
        )
    }

    // MARK: - Keep awake

    func testKeepAwakeDefaultsAndClampsOnRead() {
        XCTAssertEqual(KeepAwakePreferenceStore(defaults: defaults).state, KeepAwakePreferences())
        defaults.set("connected", forKey: "keep_awake_mode")
        defaults.set(9999, forKey: "keep_awake_timeout_minutes")
        defaults.set(true, forKey: "keep_awake_display")
        let read = KeepAwakePreferenceStore(defaults: defaults).state
        XCTAssertEqual(read, KeepAwakePreferences(mode: .whileConnected, idleTimeoutMinutes: 180, keepDisplayAwake: true))
    }

    func testKeepAwakeWritesClampAndPersist() {
        let store = KeepAwakePreferenceStore(defaults: defaults)
        store.setMode(.off)
        store.setIdleTimeoutMinutes(0)
        store.setKeepDisplayAwake(true)
        XCTAssertEqual(store.state, KeepAwakePreferences(mode: .off, idleTimeoutMinutes: 1, keepDisplayAwake: true))
        XCTAssertEqual(defaults.string(forKey: "keep_awake_mode"), "off")
        XCTAssertEqual(defaults.integer(forKey: "keep_awake_timeout_minutes"), 1)
        store.setIdleTimeoutMinutes(1)
        XCTAssertEqual(store.state.idleTimeoutMinutes, 1)
    }

    // MARK: - Updates

    func testUpdateDefaultsAndBookkeeping() {
        let store = UpdatePreferenceStore(defaults: defaults)
        XCTAssertEqual(store.state, UpdatePreferences(checksEnabled: true, skippedVersion: ""))
        XCTAssertEqual(store.lastCheckMs, 0)
        store.setChecksEnabled(false)
        store.setSkippedVersion("0.2.0")
        store.setLastCheckMs(1_700_000_000_000)
        XCTAssertEqual(store.state, UpdatePreferences(checksEnabled: false, skippedVersion: "0.2.0"))
        XCTAssertEqual(UpdatePreferenceStore(defaults: defaults).lastCheckMs, 1_700_000_000_000)
        XCTAssertEqual(defaults.bool(forKey: "updates_check_enabled"), false)
        XCTAssertEqual(defaults.string(forKey: "updates_skipped_version"), "0.2.0")
    }

    // MARK: - USB path choices

    func testUsbPathChoicesRoundTripUnderTheFleetsKeyAndShape() {
        let store = UsbPathChoiceStore(defaults: defaults)
        var bag = Set<AnyCancellable>()
        let seen = emissions(store.statePublisher, &bag)
        XCTAssertNil(store.choice(vendorId: 0x057E, productId: 0x2009))
        store.setChoice(.standard, vendorId: 0x057E, productId: 0x2009)
        store.setChoice(.standard, vendorId: 0x057E, productId: 0x2009)
        store.setChoice(.direct, vendorId: 0x2DC8, productId: 0x5006)
        XCTAssertEqual(seen().count, 2, "a repeat set does not re-emit")
        XCTAssertEqual(
            defaults.dictionary(forKey: "usb_path_choices") as? [String: String],
            ["057e:2009": "standard", "2dc8:5006": "direct"]
        )
        let reread = UsbPathChoiceStore(defaults: defaults)
        XCTAssertEqual(reread.choice(vendorId: 0x057E, productId: 0x2009), .standard)
        XCTAssertEqual(reread.choice(vendorId: 0x2DC8, productId: 0x5006), .direct)
    }

    func testAnUnknownUsbPathTokenIsNoChoice() {
        defaults.set(["057e:2009": "auto", "2dc8:5006": 7, "054c:0cda": "direct"], forKey: "usb_path_choices")
        let store = UsbPathChoiceStore(defaults: defaults)
        XCTAssertEqual(store.state, ["054c:0cda": .direct], "a newer build's token, or a value that does not read, is dropped")
    }
}
