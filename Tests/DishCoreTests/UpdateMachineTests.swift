// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import XCTest

/// Every (phase, event) pair of the update machine, with the effect lists
/// pinned in order: a reordering is a behaviour change.
final class UpdateMachineTests: XCTestCase {

    private let current = "0.1.0"

    private func idle() -> UpdateStatus {
        UpdateStatus(phase: .idle, currentVersion: current)
    }

    private func checking() -> UpdateStatus {
        reduceUpdate(idle(), .checkRequested(.periodic)).next
    }

    private func manifest(_ version: String, minimum: String = "0.1.0") -> UpdateManifest {
        UpdateManifest(
            version: version,
            minimumSupportedVersion: minimum,
            releaseNotesUrl: "https://github.com/TinkerNorth/dish-mac/releases/tag/\(version)"
        )
    }

    // MARK: - Preferences

    func testTurningChecksOffDisablesFromEveryPhase() {
        for status in [idle(), checking(), reduceUpdate(checking(), .manifestArrived(manifest("0.2.0"))).next] {
            let reduction = reduceUpdate(status, .prefsChanged(checksEnabled: false, skippedVersion: ""))
            XCTAssertEqual(reduction.next.phase, .disabled)
            XCTAssertEqual(reduction.next.error, .none)
            XCTAssertEqual(reduction.effects, [], "off means no timer re-armed")
        }
    }

    func testReEnablingIsAColdStart() {
        let disabled = reduceUpdate(idle(), .prefsChanged(checksEnabled: false, skippedVersion: "")).next
        let reduction = reduceUpdate(disabled, .prefsChanged(checksEnabled: true, skippedVersion: ""))
        XCTAssertEqual(reduction.next.phase, .idle)
        XCTAssertEqual(reduction.effects, [.scheduleNextCheck(delayMs: UpdateSchedule.startupDelayMs)])
    }

    func testPrefsCarryTheSkipWhileEnabled() {
        let reduction = reduceUpdate(idle(), .prefsChanged(checksEnabled: true, skippedVersion: "0.2.0"))
        XCTAssertEqual(reduction.next.skippedVersion, "0.2.0")
        XCTAssertEqual(reduction.effects, [])
    }

    // MARK: - Requesting a check

    func testACheckFetchesTheManifestAndMarksManualOnlyForTheButton() {
        XCTAssertEqual(reduceUpdate(idle(), .checkRequested(.periodic)).effects, [.fetchManifest(manual: false)])
        XCTAssertEqual(reduceUpdate(idle(), .checkRequested(.manual)).effects, [.fetchManifest(manual: true)])
        XCTAssertEqual(checking().phase, .checking)
    }

    func testACheckWhileDisabledOrAlreadyCheckingIsIgnored() {
        let disabled = reduceUpdate(idle(), .prefsChanged(checksEnabled: false, skippedVersion: "")).next
        XCTAssertEqual(reduceUpdate(disabled, .checkRequested(.manual)), UpdateReduction(next: disabled))
        XCTAssertEqual(reduceUpdate(checking(), .checkRequested(.periodic)), UpdateReduction(next: checking()))
    }

    func testOfflineGatesWithoutTouchingTheNetwork() {
        let offline = reduceUpdate(idle(), .reachabilityChanged(online: false)).next
        let reduction = reduceUpdate(offline, .checkRequested(.startup))
        XCTAssertEqual(reduction.next.phase, .failed)
        XCTAssertEqual(reduction.next.error, .offline)
        XCTAssertEqual(reduction.next.consecutiveFailures, 1)
        XCTAssertEqual(reduction.effects, [.scheduleNextCheck(delayMs: UpdateSchedule.backoffBaseMs)])
    }

    // MARK: - The manifest

    func testANewerReleaseIsAvailableAndNotifiesOnce() {
        let reduction = reduceUpdate(checking(), .manifestArrived(manifest("0.2.0")))
        XCTAssertEqual(reduction.next.phase, .available)
        XCTAssertEqual(reduction.next.availableVersion, "0.2.0")
        XCTAssertEqual(reduction.next.notesUrl, "https://github.com/TinkerNorth/dish-mac/releases/tag/0.2.0")
        XCTAssertFalse(reduction.next.required)
        XCTAssertEqual(reduction.next.consecutiveFailures, 0)
        XCTAssertEqual(reduction.effects, [
            .persistLastCheck,
            .notify(.available, version: "0.2.0"),
            .scheduleNextCheck(delayMs: UpdateSchedule.periodicIntervalMs)
        ])
    }

    func testTheSameOrAnOlderReleaseIsUpToDate() {
        for version in ["0.1.0", "0.0.9"] {
            let reduction = reduceUpdate(checking(), .manifestArrived(manifest(version)))
            XCTAssertEqual(reduction.next.phase, .upToDate, version)
            XCTAssertEqual(reduction.next.availableVersion, "")
            XCTAssertEqual(reduction.effects, [.persistLastCheck, .scheduleNextCheck(delayMs: UpdateSchedule.periodicIntervalMs)])
        }
    }

    func testAFloorAboveTheRunningBuildIsRequiredAndSaysSoFirst() {
        let reduction = reduceUpdate(checking(), .manifestArrived(manifest("0.3.0", minimum: "0.2.0")))
        XCTAssertEqual(reduction.next.phase, .available)
        XCTAssertTrue(reduction.next.required)
        XCTAssertEqual(reduction.effects, [
            .persistLastCheck,
            .notify(.unsupported, version: "0.3.0"),
            .notify(.available, version: "0.3.0"),
            .scheduleNextCheck(delayMs: UpdateSchedule.periodicIntervalMs)
        ])
    }

    func testASkippedVersionStaysMutedUnlessRequired() {
        var status = checking()
        status.skippedVersion = "0.2.0"
        XCTAssertEqual(reduceUpdate(status, .manifestArrived(manifest("0.2.0"))).next.phase, .upToDate)
        XCTAssertEqual(
            reduceUpdate(status, .manifestArrived(manifest("0.2.0", minimum: "0.2.0"))).next.phase,
            .available,
            "a required update ignores the skip"
        )
        XCTAssertEqual(reduceUpdate(status, .manifestArrived(manifest("0.3.0"))).next.phase, .available, "a newer release lifts the skip")
    }

    func testAManifestOutsideCheckingIsIgnored() {
        XCTAssertEqual(reduceUpdate(idle(), .manifestArrived(manifest("0.2.0"))), UpdateReduction(next: idle()))
    }

    // MARK: - Failure and backoff

    func testFailuresClimbTheLadderAndCapAtSixHours() {
        var status = checking()
        var delays: [Int] = []
        for _ in 0 ..< 8 {
            let reduction = reduceUpdate(status, .checkFailed(.http))
            delays.append(reduction.effects.compactMap { if case let .scheduleNextCheck(delay) = $0 { delay } else { nil } }.first ?? -1)
            status = reduceUpdate(reduction.next, .checkRequested(.retry)).next
        }
        let minute = 60 * 1000
        XCTAssertEqual(delays, [10 * minute, 20 * minute, 40 * minute, 80 * minute, 160 * minute, 320 * minute, 360 * minute, 360 * minute])
    }

    func testAFailureOutsideCheckingIsIgnored() {
        XCTAssertEqual(reduceUpdate(idle(), .checkFailed(.http)), UpdateReduction(next: idle()))
    }

    func testJitterSpreadsTheBackoffWithinTwentyPercent() {
        XCTAssertEqual(UpdateSchedule.jitteredDelayMs(baseMs: 1000, unit: 0), 800)
        XCTAssertEqual(UpdateSchedule.jitteredDelayMs(baseMs: 1000, unit: 0.5), 1000)
        XCTAssertEqual(UpdateSchedule.jitteredDelayMs(baseMs: 1000, unit: 1), 1200)
        XCTAssertEqual(UpdateSchedule.jitteredDelayMs(baseMs: 1000, unit: 7), 1200, "the draw is clamped")
    }

    // MARK: - Skipping and reachability

    func testSkippingTheOfferedVersionReadsUpToDate() {
        let available = reduceUpdate(checking(), .manifestArrived(manifest("0.2.0"))).next
        let reduction = reduceUpdate(available, .skipRequested(version: "0.2.0"))
        XCTAssertEqual(reduction.next.phase, .upToDate)
        XCTAssertEqual(reduction.next.skippedVersion, "0.2.0")
        XCTAssertEqual(reduction.effects, [])
    }

    func testARequiredUpdateOrAnEmptyVersionCannotBeSkipped() {
        let required = reduceUpdate(checking(), .manifestArrived(manifest("0.3.0", minimum: "0.2.0"))).next
        XCTAssertEqual(reduceUpdate(required, .skipRequested(version: "0.3.0")), UpdateReduction(next: required))
        XCTAssertEqual(reduceUpdate(idle(), .skipRequested(version: "")), UpdateReduction(next: idle()))
    }

    func testComingBackOnlineAfterAnOfflineGateReArmsOneCheck() {
        let offline = reduceUpdate(idle(), .reachabilityChanged(online: false)).next
        let gated = reduceUpdate(offline, .checkRequested(.startup)).next
        let reduction = reduceUpdate(gated, .reachabilityChanged(online: true))
        XCTAssertTrue(reduction.next.online)
        XCTAssertEqual(reduction.effects, [.scheduleNextCheck(delayMs: UpdateSchedule.reconnectCheckDelayMs)])
        XCTAssertEqual(reduceUpdate(idle(), .reachabilityChanged(online: true)).effects, [], "online while fine changes nothing")
    }
}
