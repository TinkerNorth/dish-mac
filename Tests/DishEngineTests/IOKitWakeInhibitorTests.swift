// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import XCTest
@testable import DishEngine

/// The production inhibitor against the real IOKit API: an in-process
/// assertion registered with the kernel power manager, harmless to flip and
/// retire from a test, with or without a display session (the same API
/// `caffeinate` uses from a terminal).
final class IOKitWakeInhibitorTests: XCTestCase {

    func testStartsUnheld() {
        XCTAssertEqual(IOKitWakeInhibitor().held, .none)
    }

    func testHoldingAndReleasingFlipTheReach() {
        let inhibitor = IOKitWakeInhibitor()
        inhibitor.hold(.system, reason: "test")
        XCTAssertEqual(inhibitor.held, .system)
        inhibitor.release()
        XCTAssertEqual(inhibitor.held, .none)
    }

    func testADifferentReachSwapsTheAssertion() {
        let inhibitor = IOKitWakeInhibitor()
        inhibitor.hold(.system, reason: "first")
        inhibitor.hold(.systemAndDisplay, reason: "wider")
        XCTAssertEqual(inhibitor.held, .systemAndDisplay)
        inhibitor.hold(.systemAndDisplay, reason: "again")
        XCTAssertEqual(inhibitor.held, .systemAndDisplay, "a repeated reach is a no-op")
        inhibitor.release()
    }

    func testHoldingNoneIsARelease() {
        let inhibitor = IOKitWakeInhibitor()
        inhibitor.hold(.system, reason: "test")
        inhibitor.hold(.none, reason: "test")
        XCTAssertEqual(inhibitor.held, .none)
    }

    func testReleaseIsIdempotent() {
        let inhibitor = IOKitWakeInhibitor()
        inhibitor.release()
        inhibitor.hold(.system, reason: "test")
        inhibitor.release()
        inhibitor.release()
        XCTAssertEqual(inhibitor.held, .none)
    }

    func testDeinitReleasesAHeldAssertionAndAFreshOneStartsClean() {
        do {
            let inhibitor = IOKitWakeInhibitor()
            inhibitor.hold(.system, reason: "dies on scope exit")
            XCTAssertEqual(inhibitor.held, .system)
        }
        let next = IOKitWakeInhibitor()
        XCTAssertEqual(next.held, .none)
        next.hold(.systemAndDisplay, reason: "after a dead instance")
        XCTAssertEqual(next.held, .systemAndDisplay)
        next.release()
    }
}
