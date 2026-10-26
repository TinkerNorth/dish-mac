// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import XCTest
@testable import DishCore

/// A pad's dead zones: the defaults are the noise floor every client ships,
/// a slider's percentage maps onto the axis range and back, and a percentage
/// past the slider's travel is clamped at both ends.
final class DeadzoneSettingTests: XCTestCase {

    func testTheDefaultsAreTenPercentOfTheStickAndFiveOfTheTrigger() {
        XCTAssertEqual(DeadzoneSetting.defaults, DeadzoneSetting(stickFlat: 3277, triggerFlat: 13))
        XCTAssertEqual(DeadzoneSetting.defaults.stickPercent, 10)
        XCTAssertEqual(DeadzoneSetting.defaults.triggerPercent, 5)
    }

    func testAPercentageMapsOntoTheAxisRange() {
        let setting = DeadzoneSetting(stickPercent: 10, triggerPercent: 5)
        XCTAssertEqual(setting, .defaults)
        XCTAssertEqual(DeadzoneSetting(stickPercent: 0, triggerPercent: 0), DeadzoneSetting(stickFlat: 0, triggerFlat: 0))
    }

    func testAPercentagePastTheTravelIsClampedAtBothEnds() {
        let high = DeadzoneSetting(stickPercent: 90, triggerPercent: 31)
        XCTAssertEqual(high.stickPercent, DeadzoneSetting.maxPercent)
        XCTAssertEqual(high.triggerPercent, DeadzoneSetting.maxPercent)
        let low = DeadzoneSetting(stickPercent: -4, triggerPercent: -1)
        XCTAssertEqual(low, DeadzoneSetting(stickFlat: 0, triggerFlat: 0))
    }

    func testTheTopOfTheTravelIsThirtyPercent() {
        XCTAssertEqual(DeadzoneSetting.maxPercent, 30)
        XCTAssertEqual(DeadzoneSetting(stickPercent: 30, triggerPercent: 30), DeadzoneSetting(stickFlat: 9830, triggerFlat: 77))
    }

    func testOneAxisChangesWithoutTheOther() {
        let stick = DeadzoneSetting.defaults.withStickPercent(20)
        XCTAssertEqual(stick.stickPercent, 20)
        XCTAssertEqual(stick.triggerFlat, 13)
        let trigger = DeadzoneSetting.defaults.withTriggerPercent(0)
        XCTAssertEqual(trigger.triggerFlat, 0)
        XCTAssertEqual(trigger.stickFlat, 3277)
    }

    func testTheStoredShapeIsTheDesktopsCompactJson() {
        XCTAssertEqual(DeadzoneSetting.defaults.storedJson, #"{"s":3277,"t":13}"#)
        XCTAssertEqual(DeadzoneSetting(storedJson: #"{"s":6554,"t":26}"#), DeadzoneSetting(stickFlat: 6554, triggerFlat: 26))
    }

    func testAStoredValueThatDoesNotReadIsNothingStored() {
        XCTAssertNil(DeadzoneSetting(storedJson: "garbage"))
        XCTAssertNil(DeadzoneSetting(storedJson: #"{"s":"wide"}"#))
        XCTAssertNil(DeadzoneSetting(storedJson: nil))
    }

    func testAStoredValueOutOfRangeIsClampedToTheAxis() {
        XCTAssertEqual(DeadzoneSetting(storedJson: #"{"s":99999,"t":-4}"#), DeadzoneSetting(stickFlat: 32767, triggerFlat: 0))
    }
}
