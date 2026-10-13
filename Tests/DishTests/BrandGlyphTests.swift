// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import XCTest
@testable import Dish

/// The dish faces its signal: the in-app glyph shares the fleet's geometry,
/// the reflector at +28° and the lock-on dot on the boresight.
final class BrandGlyphTests: XCTestCase {

    func testTheReflectorTiltsTowardsItsSignal() {
        XCTAssertEqual(BrandIcon.reflectorTiltDegrees, 28)
    }

    func testTheLockOnDotSitsPastTheFeedHorn() {
        XCTAssertEqual(BrandIcon.lockOn, CGPoint(x: 41.86, y: 9.46), "resources/brand/dish-connected.svg across the fleet")
    }
}
