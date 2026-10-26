// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import XCTest
@testable import DishEngine

/// Settings' intents write the stores and the facts follow, so the page
/// reads one published value; the update clock ticks exactly while
/// Settings shows; the crash report reads the log as it opens; and the
/// Diagnostics pages read the source, the recorder and the inspector
/// through the facts.
@MainActor
final class AppModelPreferencesTests: XCTestCase {

    private var defaults: UserDefaults!
    private var defaultsName: String!
    private var directory: URL!
    private var crashLog: CrashLog!
    private var model: AppModel!

    override func setUpWithError() throws {
        try super.setUpWithError()
        defaultsName = "dish.test.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsName)
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        crashLog = CrashLog(url: directory.appendingPathComponent("crash.log"))
        model = AppModel(
            store: ConnectionStore(defaults: defaults, keyStore: InMemoryKeyStore()),
            defaults: defaults,
            appVersion: "1.2.3",
            crashLog: crashLog,
            discovery: WifiConnectionManager.DiscoveryPaths { WifiConnectionManager.ScanResult(broadcast: [], mdns: []) }
        )
    }

    override func tearDown() {
        model = nil
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: defaultsName)
        super.tearDown()
    }

    private func waitUntil(timeout: TimeInterval = 5, _ predicate: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return predicate()
    }

    func testTheFactsStartOnTheStoredPreferences() {
        let facts = model.shellFacts.preferences
        XCTAssertEqual(facts.theme, model.theme.state)
        XCTAssertEqual(facts.lightbar, .followGame)
        XCTAssertEqual(facts.keepAwake, model.keepAwake.state)
        XCTAssertEqual(facts.crashReportsShared, model.crashReporting.state)
        XCTAssertFalse(facts.crashUploadPossible, "a test build carries no reporting address")
        XCTAssertTrue(facts.updateChecksEnabled)
    }

    func testTheStoreIntentsWriteTheStoresAndTheFactsFollow() {
        model.setThemeMode(.dark)
        model.setRunInBackground(false)
        model.setKeepAwakeMode(.whileConnected)
        model.setIdleTimeoutMinutes(9)
        model.setKeepDisplayAwake(true)
        model.setCrashReportsShared(false)
        model.setUpdateChecksEnabled(false)
        XCTAssertEqual(model.theme.state, .dark)
        XCTAssertFalse(model.background.state.runInBackground)
        XCTAssertEqual(model.keepAwake.state, KeepAwakePreferences(mode: .whileConnected, idleTimeoutMinutes: 9, keepDisplayAwake: true))
        XCTAssertFalse(model.crashReporting.state)
        XCTAssertFalse(model.updatePreferences.state.checksEnabled)
        let facts = model.shellFacts.preferences
        XCTAssertEqual(facts.theme, .dark)
        XCTAssertFalse(facts.runInBackground)
        XCTAssertEqual(facts.keepAwake, model.keepAwake.state)
        XCTAssertFalse(facts.crashReportsShared)
        XCTAssertFalse(facts.updateChecksEnabled)
    }

    func testTheGlobalSwitchIntentsWriteTheSettingsAndTheFactsFollow() async {
        model.setRumbleForwarded(false)
        model.setTouchpadForwarded(false)
        model.setMotionForwarded(false)
        model.setLightbarMode(.off)
        XCTAssertEqual(model.settings.flags, ForwardingFlags(motion: false, touchpad: false, rumble: false, lightbar: false))
        let drawn = await waitUntil {
            self.model.shellFacts.preferences.lightbar == .off && self.model.shellFacts.forwarding == self.model.settings.flags
        }
        XCTAssertTrue(drawn, "Settings reads the switches back from the facts")
    }

    func testSkippingMutesTheOfferedVersionOnlyWhenOneIsOffered() {
        model.skipAvailableUpdate()
        XCTAssertEqual(model.updatePreferences.state.skippedVersion, "", "nothing offered, nothing muted")
    }

    func testTheUpdateClockTicksExactlyWhileSettingsShows() {
        XCTAssertFalse(model.updates.clock.isTicking)
        model.pageAppeared(.settings)
        XCTAssertTrue(model.updates.clock.isTicking)
        XCTAssertEqual(model.shellFacts.updateClock, model.updates.clock.state)
        model.pageDisappeared(.settings)
        XCTAssertFalse(model.updates.clock.isTicking)
    }

    func testTheCrashReportReadsTheLogAsItOpens() throws {
        try Data("fatal".utf8).write(to: crashLog.url)
        XCTAssertEqual(model.shellFacts.crashLogText, "", "read at launch, before the log was written")
        model.pageAppeared(.crashReport)
        XCTAssertEqual(model.shellFacts.crashLogText, "fatal")
        XCTAssertTrue(model.shellFacts.crashLogPresent)
        model.pageDisappeared(.crashReport)
        model.discardCrashLog()
        XCTAssertEqual(model.shellFacts.crashLogText, "")
    }

    func testTheDiagnosticsPagesReadTheSourceTheRecorderAndTheInspectorThroughTheFacts() {
        model.diagnosticsLog.record([DiagnosticsEvent(atMs: 5, kind: .padAttached, subject: "Pad")])
        XCTAssertEqual(model.shellFacts.diagnosticsEvents, model.diagnosticsLog.state)
        XCTAssertEqual(model.shellFacts.diagnosticsEvents.last?.subject, "Pad")
        model.pageAppeared(.inspector(slotId: "pad"))
        XCTAssertEqual(model.shellFacts.inspection.slotId, "pad")
        model.pageDisappeared(.inspector(slotId: "pad"))
        XCTAssertEqual(model.shellFacts.inspection, .disarmed)
        model.diagnostics.refresh()
        XCTAssertEqual(model.shellFacts.diagnostics, model.diagnostics.state)
    }
}
