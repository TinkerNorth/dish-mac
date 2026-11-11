// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import XCTest

/// The claim of a pad macOS may gate on Input Monitoring: opened at once
/// when no prompt can come of it, asked once off the reader's thread when
/// undecided, and refused when denied or still undecided after asking.
final class ClaimStepTests: XCTestCase {

    func testAPadThatNeedsNoPermissionOpensWhateverTheStanding() {
        for access in [InputMonitoringAccess.granted, .denied, .undecided] {
            XCTAssertEqual(claimStep(needsInputMonitoring: false, access: access, asked: false), .open)
        }
    }

    func testAGrantedPermissionOpensAtOnce() {
        XCTAssertEqual(claimStep(needsInputMonitoring: true, access: .granted, asked: false), .open)
        XCTAssertEqual(claimStep(needsInputMonitoring: true, access: .granted, asked: true), .open, "granted at the prompt")
    }

    func testADeniedPermissionIsRefusedWithoutAskingAgain() {
        XCTAssertEqual(claimStep(needsInputMonitoring: true, access: .denied, asked: false), .refuse)
    }

    func testAnUndecidedPermissionIsAskedOnceAndThenRefused() {
        XCTAssertEqual(claimStep(needsInputMonitoring: true, access: .undecided, asked: false), .ask)
        XCTAssertEqual(claimStep(needsInputMonitoring: true, access: .undecided, asked: true), .refuse, "never a second prompt")
    }
}
