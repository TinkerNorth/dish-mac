// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Combine
import DishCore
import XCTest
@testable import DishEngine

/// The checker over a scripted gateway and an injected clock: the startup
/// gap, the fetch and parse, the schedule it arms, the manual rate limit, the
/// skip, and the notices it edge-detects.
@MainActor
final class UpdateCheckerTests: XCTestCase {

    final class ScriptedGateway: ManifestGateway {
        var results: [Result<Data, UpdateError>] = []
        private(set) var fetches = 0

        func fetchManifest() async -> Result<Data, UpdateError> {
            fetches += 1
            return results.isEmpty ? .failure(.http) : results.removeFirst()
        }
    }

    private var defaults: UserDefaults!
    private var suite: String!
    private var prefs: UpdatePreferenceStore!
    private var gateway: ScriptedGateway!
    private var now: Int64 = 1_700_000_000_000
    private var bag = Set<AnyCancellable>()

    override func setUp() {
        super.setUp()
        suite = "dish.test.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        prefs = UpdatePreferenceStore(defaults: defaults)
        gateway = ScriptedGateway()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        bag.removeAll()
        super.tearDown()
    }

    private func makeChecker(version: String = "0.1.0") -> UpdateChecker {
        UpdateChecker(preferences: prefs, gateway: gateway, currentVersion: version, now: { [self] in now })
    }

    private func manifestBody(_ version: String, minimum: String = "0.1.0") -> Data {
        Data("""
        {"schema":1,"product":"dish-mac","version":"\(version)","channel":"stable","publishedAt":"2026-10-12T20:00:00Z",
         "minimumSupportedVersion":"\(minimum)","releaseNotesUrl":"https://github.com/TinkerNorth/dish-mac/releases/tag/\(version)"}
        """.utf8)
    }

    private func settle(_ checker: UpdateChecker, timeout: TimeInterval = 4) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if checker.state.phase != .checking { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return checker.state.phase != .checking
    }

    // MARK: - The startup schedule

    func testAColdStartArmsTheStartupDelay() {
        let checker = makeChecker()
        checker.start()
        XCTAssertEqual(checker.pendingCheckDelayMs, UpdateSchedule.startupDelayMs)
        XCTAssertEqual(checker.state.phase, .idle)
    }

    func testARecentCheckDefersToTheRestOfTheMinimumGap() {
        prefs.setLastCheckMs(now - 10 * 60 * 1000)
        let checker = makeChecker()
        checker.start()
        XCTAssertEqual(checker.pendingCheckDelayMs, Int(UpdateSchedule.minCheckGapMs) - 10 * 60 * 1000)
    }

    func testALastCheckInTheFutureReadsAsDue() {
        XCTAssertEqual(startupCheckDelayMs(lastCheckMs: now + 999_999, nowMs: now), UpdateSchedule.startupDelayMs)
        XCTAssertEqual(startupCheckDelayMs(lastCheckMs: 0, nowMs: now), UpdateSchedule.startupDelayMs)
        XCTAssertEqual(startupCheckDelayMs(lastCheckMs: now - UpdateSchedule.minCheckGapMs, nowMs: now), UpdateSchedule.startupDelayMs)
    }

    func testChecksOffArmsNothing() {
        prefs.setChecksEnabled(false)
        let checker = makeChecker()
        checker.start()
        XCTAssertEqual(checker.state.phase, .disabled)
        XCTAssertNil(checker.pendingCheckDelayMs)
        XCTAssertEqual(gateway.fetches, 0)
    }

    func testStartIsIdempotent() {
        let checker = makeChecker()
        checker.start()
        checker.start()
        XCTAssertEqual(checker.pendingCheckDelayMs, UpdateSchedule.startupDelayMs)
    }

    // MARK: - A check

    func testAFiredCheckFetchesParsesAndArmsThePeriodicInterval() async {
        gateway.results = [.success(manifestBody("0.2.0"))]
        let checker = makeChecker()
        var notices: [UpdateNoticeEvent] = []
        checker.notices.sink { notices.append($0) }.store(in: &bag)
        checker.start()
        checker.firePendingCheck()
        let settled = await settle(checker)
        XCTAssertTrue(settled)
        XCTAssertEqual(checker.state.phase, .available)
        XCTAssertEqual(checker.state.availableVersion, "0.2.0")
        XCTAssertEqual(checker.pendingCheckDelayMs, UpdateSchedule.periodicIntervalMs)
        XCTAssertEqual(prefs.lastCheckMs, now, "a completed check is stamped")
        XCTAssertEqual(notices, [UpdateNoticeEvent(notice: .available, version: "0.2.0")])
    }

    func testACompletedCheckReachesTheClockAtOnce() async {
        gateway.results = [.success(manifestBody("0.1.0"))]
        let checker = makeChecker()
        XCTAssertEqual(checker.clock.state.lastCheckMs, 0)
        checker.start()
        checker.firePendingCheck()
        let settled = await settle(checker)
        XCTAssertTrue(settled)
        XCTAssertEqual(checker.clock.state, UpdateCheckTime(lastCheckMs: now, nowMs: now))
    }

    func testAnUpToDateBuildArmsThePeriodicIntervalAndSaysNothing() async {
        gateway.results = [.success(manifestBody("0.1.0"))]
        let checker = makeChecker()
        var notices: [UpdateNoticeEvent] = []
        checker.notices.sink { notices.append($0) }.store(in: &bag)
        checker.start()
        checker.firePendingCheck()
        let settled = await settle(checker)
        XCTAssertTrue(settled)
        XCTAssertEqual(checker.state.phase, .upToDate)
        XCTAssertEqual(notices, [])
    }

    func testAPortalPageIsAnInvalidManifestAndBacksOff() async {
        gateway.results = [.success(Data("<html>".utf8))]
        let checker = makeChecker()
        checker.start()
        checker.firePendingCheck()
        let settled = await settle(checker)
        XCTAssertTrue(settled)
        XCTAssertEqual(checker.state.phase, .failed)
        XCTAssertEqual(checker.state.error, .manifestInvalid)
        XCTAssertEqual(checker.pendingCheckDelayMs, UpdateSchedule.backoffBaseMs)
        XCTAssertEqual(prefs.lastCheckMs, 0, "a failed check is not stamped")
    }

    func testATransportFailureBacksOffWithTheHttpError() async {
        gateway.results = [.failure(.http)]
        let checker = makeChecker()
        checker.start()
        checker.firePendingCheck()
        let settled = await settle(checker)
        XCTAssertTrue(settled)
        XCTAssertEqual(checker.state.error, .http)
    }

    func testTheSameNoticeIsSentOncePerVersion() async {
        gateway.results = [.success(manifestBody("0.2.0")), .success(manifestBody("0.2.0"))]
        let checker = makeChecker()
        var notices: [UpdateNoticeEvent] = []
        checker.notices.sink { notices.append($0) }.store(in: &bag)
        checker.start()
        checker.firePendingCheck()
        let settled = await settle(checker)
        XCTAssertTrue(settled)
        now += UpdateSchedule.manualMinGapMs
        checker.checkNow()
        let settled2 = await settle(checker)
        XCTAssertTrue(settled2)
        XCTAssertEqual(gateway.fetches, 2)
        XCTAssertEqual(notices.count, 1)
    }

    // MARK: - Manual checks and the skip

    func testManualChecksAreRateLimited() async {
        gateway.results = [.success(manifestBody("0.1.0")), .success(manifestBody("0.1.0"))]
        let checker = makeChecker()
        checker.start()
        checker.checkNow()
        let settled = await settle(checker)
        XCTAssertTrue(settled)
        checker.checkNow()
        let settled2 = await settle(checker)
        XCTAssertTrue(settled2)
        XCTAssertEqual(gateway.fetches, 1, "a second press inside ten seconds is dropped")
        now += UpdateSchedule.manualMinGapMs
        checker.checkNow()
        let settled3 = await settle(checker)
        XCTAssertTrue(settled3)
        XCTAssertEqual(gateway.fetches, 2)
    }

    func testSkippingMutesTheOfferedVersionAndPersistsIt() async {
        gateway.results = [.success(manifestBody("0.2.0"))]
        let checker = makeChecker()
        checker.start()
        checker.firePendingCheck()
        let settled = await settle(checker)
        XCTAssertTrue(settled)
        checker.skipAvailableVersion()
        XCTAssertEqual(checker.state.phase, .upToDate)
        XCTAssertEqual(prefs.state.skippedVersion, "0.2.0")
        XCTAssertEqual(checker.state.skippedVersion, "0.2.0")
    }

    func testTurningChecksOffCancelsTheArmedCheck() {
        let checker = makeChecker()
        checker.start()
        prefs.setChecksEnabled(false)
        XCTAssertEqual(checker.state.phase, .disabled)
        prefs.setChecksEnabled(true)
        XCTAssertEqual(checker.state.phase, .idle)
        XCTAssertEqual(checker.pendingCheckDelayMs, UpdateSchedule.startupDelayMs, "re-enabling is a cold start")
    }

    func testOfflineGatesWithoutFetching() {
        let checker = makeChecker()
        checker.start()
        checker.setOnline(false)
        checker.firePendingCheck()
        XCTAssertEqual(checker.state.phase, .failed)
        XCTAssertEqual(checker.state.error, .offline)
        XCTAssertEqual(gateway.fetches, 0)
        checker.setOnline(true)
        XCTAssertEqual(checker.pendingCheckDelayMs, UpdateSchedule.reconnectCheckDelayMs)
    }
}
