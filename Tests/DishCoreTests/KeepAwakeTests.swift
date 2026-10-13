// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import XCTest

/// When Dish holds the machine awake, and how far.
final class KeepAwakeTests: XCTestCase {

    func testTheStorageTokensAreTheFleets() {
        XCTAssertEqual(KeepAwakeMode.off.rawValue, "off")
        XCTAssertEqual(KeepAwakeMode.whileControllerActive.rawValue, "controller-active")
        XCTAssertEqual(KeepAwakeMode.whileConnected.rawValue, "connected")
    }

    func testAnUnknownOrEmptyTokenReadsAsTheDefault() {
        XCTAssertEqual(KeepAwakeMode.fromStorage(nil), .whileControllerActive)
        XCTAssertEqual(KeepAwakeMode.fromStorage(""), .whileControllerActive)
        XCTAssertEqual(KeepAwakeMode.fromStorage("forever"), .whileControllerActive)
        XCTAssertEqual(KeepAwakeMode.fromStorage("connected"), .whileConnected)
    }

    func testTheTimeoutIsClampedToTheFleetsRange() {
        XCTAssertEqual(KeepAwakeLimits.clampTimeoutMinutes(0), 1)
        XCTAssertEqual(KeepAwakeLimits.clampTimeoutMinutes(5), 5)
        XCTAssertEqual(KeepAwakeLimits.clampTimeoutMinutes(999), 180)
    }

    func testActivityWindow() {
        XCTAssertTrue(controllerActive(lastInputMs: 1000, nowMs: 1500, timeoutMs: 1000))
        XCTAssertFalse(controllerActive(lastInputMs: 1000, nowMs: 2000, timeoutMs: 1000), "the window is exclusive")
        XCTAssertTrue(controllerActive(lastInputMs: 1000, nowMs: 500, timeoutMs: 1000), "a clock that steps back reads as activity")
        XCTAssertTrue(controllerActive(lastInputMs: 0, nowMs: 1_000_000, timeoutMs: 0), "a non-positive timeout never expires")
    }

    func testOffNeverHolds() {
        let prefs = KeepAwakePreferences(mode: .off, keepDisplayAwake: true)
        XCTAssertEqual(deriveKeepAwakeReach(prefs, streamingSlotCount: 3, controllerActive: true), .none)
    }

    func testNothingStreamingNeverHolds() {
        XCTAssertEqual(
            deriveKeepAwakeReach(KeepAwakePreferences(mode: .whileConnected), streamingSlotCount: 0, controllerActive: true),
            .none
        )
    }

    func testWhilePlayingLetsGoWhenThePadSitsStill() {
        let prefs = KeepAwakePreferences(mode: .whileControllerActive)
        XCTAssertEqual(deriveKeepAwakeReach(prefs, streamingSlotCount: 1, controllerActive: true), .system)
        XCTAssertEqual(deriveKeepAwakeReach(prefs, streamingSlotCount: 1, controllerActive: false), .none)
    }

    func testWhileConnectedHoldsHoweverStillThePadIs() {
        let prefs = KeepAwakePreferences(mode: .whileConnected)
        XCTAssertEqual(deriveKeepAwakeReach(prefs, streamingSlotCount: 1, controllerActive: false), .system)
    }

    func testTheDisplaySwitchWidensTheReach() {
        let prefs = KeepAwakePreferences(mode: .whileConnected, keepDisplayAwake: true)
        XCTAssertEqual(deriveKeepAwakeReach(prefs, streamingSlotCount: 1, controllerActive: false), .systemAndDisplay)
    }

    func testTheWakeStateCarriesTheCountBesideTheReach() {
        let state = deriveWakeState(streamingSlotCount: 2, controllerActive: true, prefs: KeepAwakePreferences())
        XCTAssertEqual(state, WakeState(reach: .system, streamingSlotCount: 2))
        XCTAssertNotEqual(state, deriveWakeState(streamingSlotCount: 3, controllerActive: true, prefs: KeepAwakePreferences()))
    }
}
