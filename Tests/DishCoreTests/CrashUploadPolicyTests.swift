// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import XCTest
@testable import DishCore

/// The whole privacy property, as a pure rule: an address and the user's
/// leave, neither alone.
final class CrashUploadPolicyTests: XCTestCase {

    private let dsn = "https://key@o1.ingest.us.sentry.io/2"

    func testABuildWithNoAddressCannotReportEvenWhenEnabled() {
        XCTAssertFalse(CrashUploadPolicy.shouldArm(dsn: nil, userEnabled: true))
        XCTAssertFalse(CrashUploadPolicy.shouldArm(dsn: "", userEnabled: true))
        XCTAssertFalse(CrashUploadPolicy.shouldArm(dsn: "  \n", userEnabled: true))
    }

    func testOptingOutBeatsAnyAddress() {
        XCTAssertFalse(CrashUploadPolicy.shouldArm(dsn: dsn, userEnabled: false))
    }

    func testAnAddressPlusTheSwitchArms() {
        XCTAssertTrue(CrashUploadPolicy.shouldArm(dsn: dsn, userEnabled: true))
        XCTAssertTrue(CrashUploadPolicy.carriesAddress(dsn))
    }

    func testTheEnvironmentAndTheReleaseFollowTheAddressAndTheVersion() {
        XCTAssertEqual(CrashUploadPolicy.environment(dsn: dsn), "production")
        XCTAssertEqual(CrashUploadPolicy.environment(dsn: nil), "development")
        XCTAssertEqual(CrashUploadPolicy.release(version: "1.2.3"), "dish-mac@1.2.3")
    }

    func testTheSwitchIsTheFleetsKeyAndOnByDefault() {
        XCTAssertEqual(CrashUploadPolicy.enabledKey, "crashlytics_collection_enabled")
        XCTAssertTrue(CrashUploadPolicy.defaultEnabled)
    }
}
