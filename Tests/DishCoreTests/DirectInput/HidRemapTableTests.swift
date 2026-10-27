// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import XCTest

/// A generic pad read through its stored remap: the declared sources, the
/// fixed table that maps them to the wire, and the raw change the walk
/// takes. The fixture is the plain gamepad: X Y Z Rz bytes 0-3, a 4-bit
/// hat, 10 buttons.
final class HidRemapTableTests: XCTestCase {

    private static let rest: [UInt8] = [0x7F, 0x7F, 0x7F, 0x7F, 0x08, 0x00, 0x00]

    private func gamepad() throws -> HidGamepadLayout {
        try XCTUnwrap(HidGamepadLayout.parse(descriptor: HidDescriptors.gamepad, order: .western))
    }

    private func raw(_ bytes: [UInt8]) throws -> HidRawState {
        let layout = try gamepad()
        return try XCTUnwrap(bytes.withUnsafeBufferPointer { layout.decodeRaw($0) })
    }

    private func report(_ bytes: [UInt8], _ remap: JoystickRemap) throws -> GamepadReport {
        try HidRemapTable(remap: remap).apply(raw(bytes))
    }

    func testTheDeclaredSourcesAreReadBeforeAnyMapping() throws {
        let state = try raw([0xFF, 0x00, 0x7F, 0x7F, 0x02, 0x03, 0x02])
        XCTAssertEqual(state.buttons, 0b10_0000_0011, "declared buttons 0, 1 and 9")
        XCTAssertEqual(state.dpad, WireButton.dpadRight.bit, "hat east")
        XCTAssertEqual(state.axes.lx, 32767)
        XCTAssertEqual(state.axes.ly, -32767, "HID's sign: Y at its minimum is up and negative")
    }

    func testAnotherReportsIdIsNoReading() throws {
        let withId = try XCTUnwrap(HidGamepadLayout.parse(descriptor: HidDescriptors.reportId, order: .western))
        XCTAssertEqual([UInt8]([0x03, 0xFF, 0x80]).withUnsafeBufferPointer { withId.decodeRaw($0) }?.axes.lx, 32767)
        XCTAssertNil([UInt8]([0x05, 0xFF, 0x80]).withUnsafeBufferPointer { withId.decodeRaw($0) })
        XCTAssertNil([UInt8]().withUnsafeBufferPointer { withId.decodeRaw($0) })
    }

    func testTheModelsOwnOrderReadsAsThePlainDecode() throws {
        let layout = try gamepad()
        let pressed: [UInt8] = [0xFF, 0x00, 0x40, 0xC0, 0x04, 0xFF, 0x03]
        let plain = try XCTUnwrap(decodeHid(layout, pressed))
        XCTAssertEqual(try report(pressed, defaultRemap(order: .western)), plain)
    }

    func testARemappedButtonDrivesItsNewControl() throws {
        var remap = defaultRemap(order: .western)
        remap.setButton(.faceA, 9)
        let pressed = try report([0x7F, 0x7F, 0x7F, 0x7F, 0x08, 0x00, 0x02], remap)
        XCTAssertEqual(
            pressed.buttons,
            WireButton.faceA.bit | WireButton.rightThumb.bit,
            "9 still drives R3 too, as one source may drive two controls"
        )
        XCTAssertEqual(try report([0x7F, 0x7F, 0x7F, 0x7F, 0x08, 0x01, 0x00], remap).buttons, 0, "button 0 drives nothing now")
    }

    func testTheHatDrivesTheDpadOnlyWhileTheRemapPointsAtIt() throws {
        var remap = defaultRemap(order: .western)
        let north: [UInt8] = [0x7F, 0x7F, 0x7F, 0x7F, 0x00, 0x00, 0x00]
        XCTAssertEqual(try report(north, remap).buttons, WireButton.dpadUp.bit)
        remap.hatIndex = -1
        XCTAssertEqual(try report(north, remap).buttons, 0)
    }

    func testATriggerReadsItsButtonFullOrItsAxisPositiveHalf() throws {
        var remap = defaultRemap(order: .western)
        remap.leftTrigger = TriggerSource(kind: .button, index: 4)
        remap.rightTrigger = TriggerSource(kind: .axis, index: RemapAxis.rightX)
        let state = try report([0x7F, 0x7F, 0xFF, 0x7F, 0x08, 0x10, 0x00], remap)
        XCTAssertEqual(state.lt, 255)
        XCTAssertEqual(state.rt, 255, "Z full right is the positive half's top")
        XCTAssertEqual(try report(Self.rest, remap).rt, 0, "a centred axis is a released trigger")
        remap.leftTrigger = TriggerSource(kind: .button, index: -1)
        XCTAssertEqual(try report([0x7F, 0x7F, 0x7F, 0x7F, 0x08, 0x10, 0x00], remap).lt, 0, "unassigned reads 0")
    }

    func testInvertOffPassesHIDsSignThrough() throws {
        var remap = defaultRemap(order: .western)
        let up: [UInt8] = [0x7F, 0x00, 0x7F, 0x00, 0x08, 0x00, 0x00]
        XCTAssertEqual(try report(up, remap).ly, 32767, "inverted: up is up")
        remap.invertLeftY = false
        remap.invertRightY = false
        XCTAssertEqual(try report(up, remap).ly, -32767)
        XCTAssertEqual(try report(up, remap).ry, -32767)
    }

    func testAnUnassignedOrOutOfRangeSourceReadsNeutral() throws {
        var remap = defaultRemap(order: .western)
        remap.leftStickX = -1
        remap.setButton(.faceB, 40)
        let state = try report([0xFF, 0x7F, 0x7F, 0x7F, 0x08, 0x02, 0x00], remap)
        XCTAssertEqual(state.lx, 0)
        XCTAssertEqual(state.buttons, 0)
    }

    // MARK: - The change the walk takes

    func testANewlyHeldButtonIsTheChange() throws {
        let rest = try raw(Self.rest)
        let pressed = try raw([0x7F, 0x7F, 0x7F, 0x7F, 0x08, 0x04, 0x00])
        XCTAssertEqual(rawCapture(rest: rest, previous: rest, now: pressed), RawCapture(kind: .button, index: 2))
        XCTAssertNil(rawCapture(rest: rest, previous: pressed, now: pressed), "a button still held is not a fresh choice")
        XCTAssertNil(rawCapture(rest: rest, previous: pressed, now: rest), "a release is not a choice")
    }

    func testTheDpadMovedOffCentreIsTheHat() throws {
        let rest = try raw(Self.rest)
        let north = try raw([0x7F, 0x7F, 0x7F, 0x7F, 0x00, 0x00, 0x00])
        XCTAssertEqual(rawCapture(rest: rest, previous: rest, now: north), RawCapture(kind: .hat, index: 0))
        XCTAssertNil(rawCapture(rest: rest, previous: north, now: north))
    }

    func testAnAxisCrossingOutFromItsRestIsTheChangeWithItsTravel() throws {
        let rest = try raw(Self.rest)
        let up = try raw([0x7F, 0x00, 0x7F, 0x7F, 0x08, 0x00, 0x00])
        let nudged = try raw([0x7F, 0x60, 0x7F, 0x7F, 0x08, 0x00, 0x00])
        XCTAssertNil(rawCapture(rest: rest, previous: rest, now: nudged), "jitter under the threshold")
        let capture = try XCTUnwrap(rawCapture(rest: rest, previous: nudged, now: up))
        XCTAssertEqual(capture.kind, .axis)
        XCTAssertEqual(capture.index, RemapAxis.leftY)
        XCTAssertLessThan(capture.travel, 0, "up is HID-negative")
        XCTAssertNil(rawCapture(rest: rest, previous: up, now: up), "an axis still out is not a fresh choice")
    }

    func testAButtonWinsOverAnAxisInTheSameReport() throws {
        let rest = try raw(Self.rest)
        let both = try raw([0xFF, 0x7F, 0x7F, 0x7F, 0x08, 0x01, 0x00])
        XCTAssertEqual(rawCapture(rest: rest, previous: rest, now: both), RawCapture(kind: .button, index: 0))
    }
}
