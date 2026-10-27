// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import XCTest

/// The per-model remap in the desktops' shape: the defaults verbatim, the
/// model's own order as the walk's starting point, and the stored fields,
/// ported from dish-linux's `test_joystick_remap_repository.cpp`.
final class JoystickRemapTests: XCTestCase {

    func testTheDefaultsAreTheDesktopsJoystickRemap() {
        let remap = JoystickRemap()
        XCTAssertEqual([remap.leftStickX, remap.leftStickY, remap.rightStickX, remap.rightStickY], [0, 1, 3, 4])
        XCTAssertTrue(remap.invertLeftY)
        XCTAssertTrue(remap.invertRightY)
        XCTAssertEqual(remap.leftTrigger, TriggerSource(kind: .axis, index: 2))
        XCTAssertEqual(remap.rightTrigger, TriggerSource(kind: .axis, index: 5))
        XCTAssertEqual(remap.buttons, [-1, -1, -1, -1, 7, 6, 10, 11, 4, 5, 0, 1, 2, 3])
        XCTAssertEqual(remap.hatIndex, 0)
        XCTAssertEqual(remap.guide, -1, "the desktops have no Guide")
    }

    func testTheWesternOrderStartsTheWalkFromDirectInputsOrder() {
        let remap = defaultRemap(order: .western)
        XCTAssertEqual(remap.button(.faceA), 0)
        XCTAssertEqual(remap.button(.start), 7)
        XCTAssertEqual(remap.button(.leftThumb), 8, "the Mac's western order puts L3 at 8, not the desktops' 10")
        XCTAssertEqual(remap.guide, 10)
        XCTAssertEqual(remap.button(.dpadUp), -1, "the d-pad is the hat's")
        XCTAssertEqual(remap.leftTrigger, TriggerSource(kind: .axis, index: 2))
    }

    func testAnOrderWithDigitalTriggersStartsThemOnTheirButtons() {
        let remap = defaultRemap(order: .nintendoSwitch)
        XCTAssertEqual(remap.leftTrigger, TriggerSource(kind: .button, index: 6))
        XCTAssertEqual(remap.rightTrigger, TriggerSource(kind: .button, index: 7))
        XCTAssertEqual(remap.button(.faceA), 1, "B A by position")
        XCTAssertEqual(defaultRemap(order: .eightBitDo).guide, 2, "8BitDo's Heart: the first of its two indices")
    }

    func testTheStoredFieldsRoundTrip() {
        var remap = defaultRemap(order: .playStationClassic)
        remap.invertRightY = false
        remap.hatIndex = -1
        let fields = remapFields(remap)
        XCTAssertEqual(fields["btn"] as? [Int], remap.buttons)
        XCTAssertEqual(fields["ltk"] as? Int, 1, "a button trigger is kind 1")
        XCTAssertEqual(fields["iry"] as? Bool, false)
        XCTAssertEqual(DishCore.remap(fields: fields), remap)
    }

    func testAMissingOrGarbledFieldKeepsItsDefault() {
        let remap = DishCore.remap(fields: ["lsx": 4, "ily": "yes", "lti": true, "gd": 9, "future": 1])
        XCTAssertEqual(remap.leftStickX, 4)
        XCTAssertTrue(remap.invertLeftY, "a string is not a Boolean")
        XCTAssertEqual(remap.leftTrigger.index, 2, "a Boolean is not an index")
        XCTAssertEqual(remap.guide, 9)
        XCTAssertEqual(remap.rightStickY, 4)
    }

    func testAButtonArrayOfTheWrongLengthIsIgnoredWhole() {
        XCTAssertEqual(DishCore.remap(fields: ["btn": [1, 2, 3]]).buttons, JoystickRemap().buttons)
        var mixed: [Any] = JoystickRemap().buttons
        mixed[10] = 9
        mixed[11] = "x"
        let read = DishCore.remap(fields: ["btn": mixed]).buttons
        XCTAssertEqual(read[10], 9)
        XCTAssertEqual(read[11], 1, "a garbled element keeps its own default")
    }
}
