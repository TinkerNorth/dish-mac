// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import XCTest
@testable import Dish

/// Coverage for the feature-toggle layer:
///
///   * `FeatureSettings` — first-launch defaults, `UserDefaults` round-trip,
///     and the `flags` snapshot it hands to the gate.
///   * `ForwardingGate` — the thread-safe mirror the hot-path senders read.
///   * `GamepadInputProcessor.publishTouchpad` — sender forwarding.
///
/// Each `FeatureSettings` test uses an isolated `UserDefaults` suite so the
/// developer's real preferences are never touched and tests don't cross-talk.
@MainActor
final class FeatureSettingsTests: XCTestCase {

    /// A throwaway `UserDefaults` suite, wiped on teardown.
    private func makeSuite() -> (UserDefaults, String) {
        let name = "dish.test.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: name) else {
            preconditionFailure("could not create isolated UserDefaults test suite")
        }
        return (defaults, name)
    }

    // MARK: - Defaults

    func testFreshInstallDefaultsEverythingOn() {
        let (defaults, name) = makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }

        let settings = FeatureSettings(defaults: defaults)
        XCTAssertTrue(settings.motionEnabled)
        XCTAssertTrue(settings.rumbleEnabled)
        XCTAssertTrue(settings.touchpadEnabled)
        XCTAssertEqual(settings.lightbarMode, .followGame)
    }

    // MARK: - Persistence round-trip

    func testMotionTogglePersistsAcrossInstances() {
        let (defaults, name) = makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }

        let first = FeatureSettings(defaults: defaults)
        first.motionEnabled = false

        let second = FeatureSettings(defaults: defaults)
        XCTAssertFalse(second.motionEnabled)
        // Untouched toggles keep their default.
        XCTAssertTrue(second.rumbleEnabled)
    }

    func testEveryTogglePersistsIndependently() {
        let (defaults, name) = makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }

        let first = FeatureSettings(defaults: defaults)
        first.motionEnabled = false
        first.rumbleEnabled = false
        first.touchpadEnabled = false

        let second = FeatureSettings(defaults: defaults)
        XCTAssertFalse(second.motionEnabled)
        XCTAssertFalse(second.rumbleEnabled)
        XCTAssertFalse(second.touchpadEnabled)
    }

    func testLightbarModePersists() {
        let (defaults, name) = makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }

        let first = FeatureSettings(defaults: defaults)
        first.lightbarMode = .off

        let second = FeatureSettings(defaults: defaults)
        XCTAssertEqual(second.lightbarMode, .off)
    }

    // MARK: - flags snapshot

    func testFlagsMirrorAllOn() {
        let (defaults, name) = makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }

        let settings = FeatureSettings(defaults: defaults)
        let flags = settings.flags
        XCTAssertTrue(flags.motion)
        XCTAssertTrue(flags.touchpad)
        XCTAssertTrue(flags.rumble)
        XCTAssertTrue(flags.lightbar) // followGame → lightbar on
    }

    func testFlagsReflectDisabledToggles() {
        let (defaults, name) = makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }

        let settings = FeatureSettings(defaults: defaults)
        settings.motionEnabled = false
        settings.touchpadEnabled = false

        let flags = settings.flags
        XCTAssertFalse(flags.motion)
        XCTAssertFalse(flags.touchpad)
        XCTAssertTrue(flags.rumble) // untouched
    }

    func testFlagsLightbarFalseWhenModeOff() {
        let (defaults, name) = makeSuite()
        defer { defaults.removePersistentDomain(forName: name) }

        let settings = FeatureSettings(defaults: defaults)
        settings.lightbarMode = .off
        XCTAssertFalse(settings.flags.lightbar)

        settings.lightbarMode = .followGame
        XCTAssertTrue(settings.flags.lightbar)
    }

    // MARK: - LightbarMode

    func testLightbarModeRawValuesAreStable() {
        // The raw value is persisted, so it must not drift.
        XCTAssertEqual(LightbarMode.followGame.rawValue, "followGame")
        XCTAssertEqual(LightbarMode.off.rawValue, "off")
        XCTAssertEqual(LightbarMode.allCases.count, 2)
    }
}

/// `ForwardingGate` is `Sendable`, not actor-isolated — these run off the main
/// actor deliberately, the same way the hot-path senders call it.
final class ForwardingGateTests: XCTestCase {

    func testDefaultSnapshotIsAllOn() {
        let gate = ForwardingGate()
        let flags = gate.snapshot()
        XCTAssertTrue(flags.motion)
        XCTAssertTrue(flags.touchpad)
        XCTAssertTrue(flags.rumble)
        XCTAssertTrue(flags.lightbar)
    }

    func testUpdateIsReflectedInSnapshot() {
        let gate = ForwardingGate()
        gate.update(ForwardingFlags(motion: false, touchpad: true, rumble: false, lightbar: true))
        let flags = gate.snapshot()
        XCTAssertFalse(flags.motion)
        XCTAssertTrue(flags.touchpad)
        XCTAssertFalse(flags.rumble)
        XCTAssertTrue(flags.lightbar)
    }

    func testLastUpdateWins() {
        let gate = ForwardingGate()
        gate.update(ForwardingFlags(motion: false))
        gate.update(ForwardingFlags(motion: true))
        XCTAssertTrue(gate.snapshot().motion)
    }

    /// Hammer the gate from many concurrent readers + writers; the test
    /// passes if it completes without a sanitizer trip or crash.
    func testConcurrentAccessIsSafe() {
        let gate = ForwardingGate()
        let iterations = 2000
        let group = DispatchGroup()
        for idx in 0 ..< iterations {
            group.enter()
            DispatchQueue.global().async {
                if idx.isMultiple(of: 2) {
                    gate.update(ForwardingFlags(motion: idx.isMultiple(of: 4)))
                } else {
                    _ = gate.snapshot()
                }
                group.leave()
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
    }
}

/// Touchpad path on the processor — `publishTouchpad` is a pure pass-through
/// to `touchpadSender` (a touchpad is an absolute surface, no deadzone) plus
/// the protocol-1 `eventTimeMs` stamp (uptime ms off the injectable `nowNs`
/// clock — contract §0x000C).
final class TouchpadProcessorTests: XCTestCase {

    private struct Captured: Equatable {
        let id: String
        let f0a: Bool
        let f0id: UInt8
        let f0x: Int16
        let f0y: Int16
        let f1a: Bool
        let f1id: UInt8
        let f1x: Int16
        let f1y: Int16
        let button: Bool
        let eventMs: UInt32
    }

    private func install(_ proc: GamepadInputProcessor, into captured: @escaping (Captured) -> Void) {
        proc.touchpadSender = { id, f0a, f0id, f0x, f0y, f1a, f1id, f1x, f1y, btn, eventMs in
            captured(Captured(
                id: id,
                f0a: f0a,
                f0id: f0id,
                f0x: f0x,
                f0y: f0y,
                f1a: f1a,
                f1id: f1id,
                f1x: f1x,
                f1y: f1y,
                button: btn,
                eventMs: eventMs
            ))
        }
    }

    func testPublishTouchpadForwardsAllFields() {
        var captured: Captured?
        let proc = GamepadInputProcessor()
        install(proc) { captured = $0 }
        proc.publishTouchpad(
            deviceId: "pad",
            finger0Active: true,
            finger0Id: 7,
            finger0X: 1234,
            finger0Y: -567,
            finger1Active: false,
            finger1Id: 3,
            finger1X: 0,
            finger1Y: 0,
            buttonPressed: true,
            nowNs: 5_000_000_000
        )
        XCTAssertEqual(
            captured,
            Captured(
                id: "pad",
                f0a: true,
                f0id: 7,
                f0x: 1234,
                f0y: -567,
                f1a: false,
                f1id: 3,
                f1x: 0,
                f1y: 0,
                button: true,
                eventMs: 5000
            )
        )
    }

    func testPublishTouchpadNoSenderIsNoOp() {
        // No sender installed — must not crash.
        let proc = GamepadInputProcessor()
        proc.publishTouchpad(
            deviceId: "pad",
            finger0Active: false,
            finger0Id: 0,
            finger0X: 0,
            finger0Y: 0,
            finger1Active: false,
            finger1Id: 0,
            finger1X: 0,
            finger1Y: 0,
            buttonPressed: false
        )
    }

    func testPublishTouchpadCarriesFullInt16Range() {
        var captured: Captured?
        let proc = GamepadInputProcessor()
        install(proc) { captured = $0 }
        proc.publishTouchpad(
            deviceId: "pad",
            finger0Active: true,
            finger0Id: 0,
            finger0X: Int16.max,
            finger0Y: Int16.min,
            finger1Active: true,
            finger1Id: 1,
            finger1X: -1,
            finger1Y: 1,
            buttonPressed: false
        )
        XCTAssertEqual(captured?.f0x, Int16.max)
        XCTAssertEqual(captured?.f0y, Int16.min)
        XCTAssertEqual(captured?.f1x, -1)
        XCTAssertEqual(captured?.f1y, 1)
    }

    func testEventTimeMsTruncatesNanosecondsToMilliseconds() {
        // The wire stamp is uptime ms as u32 — a >49.7-day uptime wraps by
        // design (the receiver consumes deltas). 2^32 ms + 1 ms wraps to 1.
        var captured: Captured?
        let proc = GamepadInputProcessor()
        install(proc) { captured = $0 }
        proc.publishTouchpad(
            deviceId: "pad",
            finger0Active: false,
            finger0Id: 0,
            finger0X: 0,
            finger0Y: 0,
            finger1Active: false,
            finger1Id: 0,
            finger1X: 0,
            finger1Y: 0,
            buttonPressed: false,
            nowNs: (UInt64(UInt32.max) + 2) * 1_000_000
        )
        XCTAssertEqual(captured?.eventMs, 1)
    }
}
