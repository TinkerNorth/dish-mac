// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import XCTest
@testable import DishEngine

/// What the window's shell reads beyond the slot list, and the pages'
/// lifecycle intents: the running version and the keep-awake reach reach
/// the shell, Settings re-reads whether a crash log waits, discarding it
/// clears the row, and the inspector is armed exactly while its page shows.
@MainActor
final class AppModelShellTests: XCTestCase {

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

    private func leaveACrashLog() throws {
        try Data("fatal".utf8).write(to: crashLog.url)
    }

    func testTheShellReadsTheRunningVersionAndAMachineAtRest() {
        XCTAssertEqual(model.shellFacts.update.currentVersion, "1.2.3")
        XCTAssertEqual(model.shellFacts.wake, WakeState(reach: .none, streamingSlotCount: 0))
        XCTAssertFalse(model.shellFacts.crashLogPresent)
    }

    func testSettingsSeesACrashLogLeftSinceLaunch() throws {
        try leaveACrashLog()
        XCTAssertFalse(model.shellFacts.crashLogPresent, "read at launch, before the log was written")
        model.pageAppeared(.settings)
        XCTAssertTrue(model.shellFacts.crashLogPresent)
        model.pageDisappeared(.settings)
        XCTAssertTrue(model.shellFacts.crashLogPresent, "leaving Settings changes nothing")
    }

    func testDiscardingTheCrashLogClearsItsRow() throws {
        try leaveACrashLog()
        model.pageAppeared(.settings)
        model.discardCrashLog()
        XCTAssertFalse(model.shellFacts.crashLogPresent)
        XCTAssertFalse(crashLog.exists)
    }

    func testTheInspectorIsArmedExactlyWhileItsPageShows() {
        model.pageAppeared(.inspector(slotId: "pad"))
        XCTAssertEqual(model.inspector.state.slotId, "pad")
        model.pageDisappeared(.inspector(slotId: "pad"))
        XCTAssertNil(model.inspector.state.slotId)
    }
}
