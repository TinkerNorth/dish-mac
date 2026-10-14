// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import XCTest
@testable import DishEngine

/// The switch: on by default under the fleet's key, persisted, every flip
/// reaching the uploader with the stored value first, and the model handing
/// its controller the app's uploader.
@MainActor
final class CrashReportingControllerTests: XCTestCase {

    private final class FakeUploader: CrashUploader {
        var canUpload = true
        var flips: [Bool] = []

        func setEnabled(_ enabled: Bool) {
            flips.append(enabled)
        }
    }

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

    func testOnByDefaultUnderTheFleetsKeyAndPersisted() {
        let controller = CrashReportingController(defaults: defaults)
        XCTAssertTrue(controller.state)
        controller.setEnabled(false)
        XCTAssertFalse(controller.state)
        XCTAssertEqual(defaults.object(forKey: "crashlytics_collection_enabled") as? Bool, false)
        XCTAssertFalse(CrashReportingController(defaults: defaults).state, "the choice survives a relaunch")
        controller.setEnabled(true)
        XCTAssertTrue(CrashReportingController(defaults: defaults).state)
    }

    func testTheStoredValueReachesTheUploaderBeforeAnythingElse() {
        defaults.set(false, forKey: "crashlytics_collection_enabled")
        let uploader = FakeUploader()
        let controller = CrashReportingController(defaults: defaults, uploader: uploader)
        XCTAssertEqual(uploader.flips, [false], "the stored opt-out reaches the SDK before a report could be sent")
        controller.setEnabled(true)
        controller.setEnabled(false)
        XCTAssertEqual(uploader.flips, [false, true, false])
    }

    func testTheWordsBesideTheSwitchReadTheBuildsTruth() {
        let uploader = FakeUploader()
        let controller = CrashReportingController(defaults: defaults, uploader: uploader)
        XCTAssertTrue(controller.uploadPossible)
        uploader.canUpload = false
        XCTAssertFalse(controller.uploadPossible)
        XCTAssertFalse(CrashReportingController(defaults: defaults).uploadPossible, "no uploader, nothing possible")
    }

    func testWithoutAnUploaderTheSwitchStillKeepsItsValue() {
        let controller = CrashReportingController(defaults: defaults)
        controller.setEnabled(false)
        XCTAssertFalse(controller.state)
        XCTAssertFalse(CrashReportingController(defaults: defaults).state)
    }

    func testTheModelHandsItsControllerTheAppsUploader() {
        let uploader = FakeUploader()
        let model = AppModel(
            store: ConnectionStore(defaults: defaults, keyStore: InMemoryKeyStore()),
            defaults: defaults,
            audioDependencies: AudioDependencies(
                ports: FakeAudioPorts(),
                functions: PadAudioFunctionSource(read: { [] }),
                permission: MicPermissionGate(read: { false }, ask: { $0(false) })
            ),
            crashUploader: uploader
        )
        XCTAssertEqual(uploader.flips, [true], "on by default, and the SDK hears it at construction")
        model.crashReporting.setEnabled(false)
        XCTAssertEqual(uploader.flips, [true, false])
        XCTAssertTrue(model.crashReporting.uploadPossible)
    }
}
