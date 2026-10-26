// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import XCTest
@testable import DishCore

/// A pad without the extended profile, read through its physical profile:
/// the generic table reads Apple's names as the extended path reads the
/// same inputs, the N64 table is Android's policy, and the C buttons rail
/// the right stick up-positive.
final class ProfileLayoutTests: XCTestCase {

    private func role(_ name: String, in layout: ProfileLayout) -> ProfileButtonRole? {
        layout.buttons.first { $0.names.contains(name) }?.role
    }

    private func direction(_ name: String, in layout: ProfileLayout) -> ProfileDirectionRole? {
        layout.directions.first { $0.names.contains(name) }?.role
    }

    // MARK: - The tables

    func testTheGenericLayoutReadsApplesNamesAsTheExtendedPathReadsThem() {
        let layout = ProfileLayout.of(.generic)
        let expected: [(String, ProfileButtonRole)] = [
            ("Button A", .button(.faceA)), ("Button B", .button(.faceB)), ("Button X", .button(.faceX)),
            ("Button Y", .button(.faceY)), ("Left Shoulder", .button(.leftShoulder)), ("Right Shoulder", .button(.rightShoulder)),
            ("Left Trigger", .trigger(.left)), ("Right Trigger", .trigger(.right)), ("Button Menu", .button(.start)),
            ("Button Options", .button(.back)), ("Button Home", .button(.guide)),
            ("Left Thumbstick Button", .button(.leftThumb)), ("Right Thumbstick Button", .button(.rightThumb))
        ]
        for (name, wanted) in expected {
            XCTAssertEqual(role(name, in: layout), wanted, name)
        }
        XCTAssertEqual(layout.buttons.count, expected.count, "no row beyond Apple's names")
        XCTAssertEqual(direction("Direction Pad", in: layout), .dpad)
        XCTAssertEqual(direction("Left Thumbstick", in: layout), .stick(.left))
        XCTAssertEqual(direction("Right Thumbstick", in: layout), .stick(.right))
    }

    /// dish-android `gamepad_input.cpp` `applyN64Key` / `applyCButtonStick`.
    func testTheN64LayoutIsAndroidsPolicy() {
        let layout = ProfileLayout.of(.n64)
        let expected: [(String, ProfileButtonRole)] = [
            ("Button A", .button(.faceA)), ("Button B", .button(.faceB)),
            ("Left Shoulder", .button(.leftShoulder)), ("Right Shoulder", .button(.rightShoulder)),
            ("Button Z", .fullTrigger(.left)), ("Button ZR", .fullTrigger(.right)),
            ("Button Menu", .button(.start)), ("Button Home", .button(.guide)), ("Button Share", .button(.back)),
            ("Button C Up", .cButton(.up)), ("Button C Down", .cButton(.down)),
            ("Button C Left", .cButton(.left)), ("Button C Right", .cButton(.right))
        ]
        for (name, wanted) in expected {
            XCTAssertEqual(role(name, in: layout), wanted, name)
        }
        XCTAssertEqual(layout.buttons.count, expected.count, "one row per N64 input")
        XCTAssertNil(role("Button X", in: layout), "the N64 has no X; a pad that names one has it logged, not guessed")
        XCTAssertNil(role("Button Y", in: layout))
        XCTAssertEqual(direction("Direction Pad", in: layout), .dpad)
        XCTAssertEqual(direction("Left Thumbstick", in: layout), .stick(.left), "the control stick, up-positive, not negated")
        XCTAssertNil(direction("Right Thumbstick", in: layout), "the C buttons own the right stick")
    }

    func testAnN64IsKnownByItsCategoryItsVendorNameOrACButtonAndEveryOtherPadIsGeneric() {
        let byCategory = chooseProfileLayout(productCategory: "N64 Controller", vendorName: nil, elementNames: [])
        XCTAssertEqual(byCategory, ProfileLayoutChoice(kind: .n64, evidence: .productCategory))
        let byVendor = chooseProfileLayout(productCategory: "HID", vendorName: "Nintendo N64 Controller", elementNames: [])
        XCTAssertEqual(byVendor, ProfileLayoutChoice(kind: .n64, evidence: .vendorName))
        let byElement = chooseProfileLayout(productCategory: "HID", vendorName: "Nintendo", elementNames: ["Button A", "C Up"])
        XCTAssertEqual(byElement, ProfileLayoutChoice(kind: .n64, evidence: .elementName))
        let snes = chooseProfileLayout(productCategory: "SNES Controller", vendorName: "Nintendo", elementNames: ["Button A"])
        XCTAssertEqual(snes, ProfileLayoutChoice(kind: .generic, evidence: .none))
    }

    // MARK: - Resolving against a pad

    func testTheFirstNameThePadCarriesBindsAndARowItLacksIsMissing() {
        let elements = [["Button A"], ["Left Trigger"], ["Direction Pad"], ["Right Thumbstick Up"]]
        let resolved = resolveProfile(.of(.n64), elements: elements)
        XCTAssertEqual(resolved.buttons, [
            ProfileBinding(name: "Button A", role: .button(.faceA)),
            ProfileBinding(name: "Left Trigger", role: .fullTrigger(.left)),
            ProfileBinding(name: "Right Thumbstick Up", role: .cButton(.up))
        ])
        XCTAssertEqual(resolved.directions, [ProfileBinding(name: "Direction Pad", role: .dpad)])
        XCTAssertEqual(resolved.missing, [
            "Button B", "Left Shoulder", "Right Shoulder", "Right Trigger", "Button Menu", "Button Home", "Button Share",
            "Button C Down", "Button C Left", "Button C Right", "Left Thumbstick"
        ])
    }

    func testAnElementNoRowClaimsIsReportedOnceByItsAliasesAndADirectionsPartsAreClaimed() {
        let elements = [
            ["Button A"], ["Direction Pad"], ["Direction Pad Up"], ["Direction Pad X Axis"], ["Paddle 1", "Back Left Button 0"],
            ["Mystery"]
        ]
        let resolved = resolveProfile(.of(.generic), elements: elements)
        XCTAssertEqual(resolved.unclaimed, ["Back Left Button 0/Paddle 1", "Mystery"])
    }

    func testAPadThatSteersWithNothingOrPressesNothingIsNotAdopted() {
        let steersAndPresses = resolveProfile(.of(.generic), elements: [["Direction Pad"], ["Button A"]])
        XCTAssertTrue(steersAndPresses.isAdoptable)
        let pressesOnly = resolveProfile(.of(.generic), elements: [["Button A"]])
        XCTAssertFalse(pressesOnly.isAdoptable)
        let steersOnly = resolveProfile(.of(.generic), elements: [["Left Thumbstick"]])
        XCTAssertFalse(steersOnly.isAdoptable)
    }

    // MARK: - The C buttons and the right stick

    func testCUpAndCDownRailTheRightStickYUpPositiveAndBothCancel() {
        XCTAssertEqual(wireReport(from: ProfileSample(cButtons: [.up])).ry, 32767)
        XCTAssertEqual(wireReport(from: ProfileSample(cButtons: [.down])).ry, -32767)
        XCTAssertEqual(wireReport(from: ProfileSample(cButtons: [.up, .down])).ry, 0)
        XCTAssertEqual(wireReport(from: ProfileSample(cButtons: [.up])).rx, 0, "a vertical C leaves X centred")
    }

    func testCLeftAndCRightRailTheRightStickXAndBothCancel() {
        XCTAssertEqual(wireReport(from: ProfileSample(cButtons: [.left])).rx, -32767)
        XCTAssertEqual(wireReport(from: ProfileSample(cButtons: [.right])).rx, 32767)
        XCTAssertEqual(wireReport(from: ProfileSample(cButtons: [.left, .right])).rx, 0)
    }

    func testWithoutACButtonTheRightStickPassesThrough() {
        let sample = ProfileSample(pad: PadSample(rightX: 0.5, rightY: -1))
        XCTAssertEqual(padSample(from: sample), sample.pad)
        let report = wireReport(from: sample)
        XCTAssertEqual(report.rx, 16383)
        XCTAssertEqual(report.ry, -32767)
    }

    // MARK: - Sampling

    func testAHeldTriggerPullsFullyAndTwoPullsReadTheFurther() {
        var sample = ProfileSample()
        sample.press(.fullTrigger(.left))
        sample.pull(.right, 0.25)
        sample.pull(.right, 0.75)
        sample.pull(.right, 0.5)
        let report = wireReport(from: sample)
        XCTAssertEqual(report.lt, 255, "Z is LT 255")
        XCTAssertEqual(report.rt, 191)
    }

    func testAButtonSetsItsBitACButtonItsRailAndAStickSteersItsSide() {
        var sample = ProfileSample()
        sample.press(.button(.guide))
        sample.press(.cButton(.right))
        sample.press(.trigger(.right))
        sample.steer(.left, x: -1, y: 1)
        sample.steer(.right, x: 0.5, y: 0.5)
        XCTAssertEqual(sample.pad.pressed, [.guide])
        XCTAssertEqual(sample.cButtons, [.right])
        XCTAssertEqual(sample.pad.rightTrigger, 1)
        let report = wireReport(from: sample)
        XCTAssertEqual(report.lx, -32767)
        XCTAssertEqual(report.ly, 32767, "the control stick pushed up is up on the wire")
        XCTAssertEqual(report.rx, 32767, "a held C button takes the right stick")
        XCTAssertEqual(report.ry, 0)
    }

    func testTheN64AsAndroidSendsIt() {
        var sample = ProfileSample()
        for role in [ProfileButtonRole.button(.faceA), .button(.start), .button(.guide), .button(.back), .fullTrigger(.right)] {
            sample.press(role)
        }
        sample.press(.cButton(.down))
        sample.steer(.left, x: 0, y: -1)
        let report = wireReport(from: sample)
        XCTAssertEqual(report.buttons, WireButton.faceA.bit | WireButton.start.bit | WireButton.guide.bit | WireButton.back.bit)
        XCTAssertEqual(report.lt, 0)
        XCTAssertEqual(report.rt, 255, "ZR is RT 255")
        XCTAssertEqual(report.ly, -32767)
        XCTAssertEqual(report.ry, -32767, "C-down is the right stick pulled down")
    }

    func testTheSidesOfEveryRoleAreRead() {
        XCTAssertEqual(ProfileButtonRole.trigger(.left).analogSide, .left)
        XCTAssertNil(ProfileButtonRole.fullTrigger(.left).analogSide, "a full trigger is read as held")
        XCTAssertNil(ProfileButtonRole.button(.faceA).analogSide)
        XCTAssertNil(ProfileButtonRole.cButton(.up).analogSide)
        XCTAssertEqual(ProfileDirectionRole.stick(.right).stickSide, .right)
        XCTAssertNil(ProfileDirectionRole.dpad.stickSide)
    }
}
