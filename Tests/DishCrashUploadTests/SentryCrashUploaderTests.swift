// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import Sentry
import XCTest
@testable import DishCrashUpload

/// The uploader stays inert without an address, whatever the switch says,
/// which is what lets a test run never transmit; the options it would arm
/// with carry the crash and nothing else; the report names no user or host.
final class SentryCrashUploaderTests: XCTestCase {

    func testWithoutAnAddressTheUploaderNeverArms() {
        let uploader = SentryCrashUploader(dsn: nil, appVersion: "1.0.0")
        XCTAssertFalse(uploader.canUpload)
        uploader.setEnabled(true)
        XCTAssertFalse(uploader.active)
        uploader.setEnabled(false)
        XCTAssertFalse(uploader.active)
        XCTAssertFalse(SentryCrashUploader(dsn: "", appVersion: "1.0.0").canUpload)
    }

    func testAnAddressMakesUploadPossibleButTheSwitchStillDecides() {
        let uploader = SentryCrashUploader(dsn: "https://key@o1.ingest.us.sentry.io/2", appVersion: "1.0.0")
        XCTAssertTrue(uploader.canUpload)
        XCTAssertFalse(uploader.active, "nothing arms until the switch is read")
    }

    func testTheOptionsCarryTheCrashAndNothingElse() {
        let options = Options()
        configure(options, dsn: "https://key@o1.ingest.us.sentry.io/2", release: "dish-mac@1.0.0")
        XCTAssertEqual(options.releaseName, "dish-mac@1.0.0")
        XCTAssertEqual(options.environment, "production")
        XCTAssertFalse(options.sendDefaultPii)
        XCTAssertFalse(options.enableAutoSessionTracking)
        XCTAssertFalse(options.enableAutoBreadcrumbTracking)
        XCTAssertFalse(options.enableSwizzling)
        XCTAssertFalse(options.enableNetworkTracking)
        XCTAssertEqual(options.maxBreadcrumbs, 0)
        XCTAssertNotNil(options.beforeSend)
    }

    func testTheReportNamesNoUserNoHostAndNoTrail() {
        let event = Event()
        event.user = User(userId: "someone")
        event.serverName = "emirs-mac.local"
        event.breadcrumbs = [Breadcrumb(level: .info, category: "ui")]
        let scrubbed = scrub(event)
        XCTAssertNil(scrubbed?.user)
        XCTAssertNil(scrubbed?.serverName)
        XCTAssertNil(scrubbed?.breadcrumbs)
    }
}
