// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import XCTest
@testable import Dish

/// The dish faces its signal: the in-app glyph shares the fleet's geometry,
/// the reflector at +28° and the lock-on dot on the boresight, and the
/// rail's controller is the fleet's pad.
final class BrandGlyphTests: XCTestCase {

    func testTheReflectorTiltsTowardsItsSignal() {
        XCTAssertEqual(BrandIcon.reflectorTiltDegrees, 28)
    }

    func testTheLockOnDotSitsPastTheFeedHorn() {
        XCTAssertEqual(BrandIcon.lockOn, CGPoint(x: 41.86, y: 9.46), "resources/brand/dish-connected.svg across the fleet")
    }

    func testTheControllerGlyphIsTheFleetsPad() {
        XCTAssertEqual(BrandIcon.padBody, CGRect(x: 6, y: 21, width: 52, height: 24), "resources/brand/pad.svg across the fleet")
        XCTAssertEqual(BrandIcon.padGripCentres, [CGPoint(x: 17, y: 42), CGPoint(x: 47, y: 42)])
        XCTAssertEqual(BrandIcon.padGripRadius, 11)
        XCTAssertEqual(BrandIcon.padCross, [CGRect(x: 11, y: 29, width: 15, height: 5), CGRect(x: 16, y: 24, width: 5, height: 15)])
        XCTAssertEqual(
            BrandIcon.padFaceButtons,
            [CGPoint(x: 43, y: 26), CGPoint(x: 50, y: 32), CGPoint(x: 43, y: 38), CGPoint(x: 36, y: 32)]
        )
        XCTAssertEqual(BrandIcon.padFaceButtonRadius, 3.5)
    }
}
