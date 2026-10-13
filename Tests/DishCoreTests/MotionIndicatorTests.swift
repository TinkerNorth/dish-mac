// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import XCTest
@testable import DishCore

/// The most blocking reason wins, in declaration order.
final class MotionIndicatorTests: XCTestCase {

    private let allGood = MotionIndicatorInputs(
        hasGyro: true, userEnabled: true, carriesOnConnection: true, hostHasSinkForType: true, backendOk: true
    )

    func testEverythingInPlaceIsForwarding() {
        XCTAssertEqual(motionIndicatorFor(allGood), .forwarding)
    }

    func testEachBlockerInPrecedenceOrder() {
        var inputs = allGood
        inputs.backendOk = false
        XCTAssertEqual(motionIndicatorFor(inputs), .backendBroken)
        inputs.hostHasSinkForType = false
        XCTAssertEqual(motionIndicatorFor(inputs), .noHostSink, "no sink hides the backend's health")
        inputs.carriesOnConnection = false
        XCTAssertEqual(motionIndicatorFor(inputs), .notForwarded)
        inputs.userEnabled = false
        XCTAssertEqual(motionIndicatorFor(inputs), .userDisabled)
        inputs.hasGyro = false
        XCTAssertEqual(motionIndicatorFor(inputs), .unavailable, "no hardware is the most blocking reason")
    }

    func testABrokenBackendOnlyMattersOnceTheHostHasASink() {
        var inputs = allGood
        inputs.hostHasSinkForType = false
        inputs.backendOk = true
        XCTAssertEqual(motionIndicatorFor(inputs), .noHostSink)
    }
}
