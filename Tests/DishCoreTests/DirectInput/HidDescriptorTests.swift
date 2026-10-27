// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import XCTest

/// The report-descriptor walk: the field map each fixture declares, ported
/// from the desktops' `test_usb_hid_layout.cpp` and
/// `test_usb_hid_layout_orders.cpp`.
final class HidDescriptorTests: XCTestCase {

    private func field(_ offset: UInt16, _ size: UInt8, _ low: Int32, _ high: Int32) -> HidField {
        HidField(bitOffset: offset, bitSize: size, logicalMin: low, logicalMax: high)
    }

    func testAStandardGamepadDescriptorParsesToItsFieldMap() throws {
        let layout = try XCTUnwrap(HidGamepadLayout.parse(descriptor: HidDescriptors.gamepad))
        XCTAssertEqual(layout.reportId, 0)
        XCTAssertEqual(layout.lx, field(0, 8, 0, 255))
        XCTAssertEqual(layout.ly?.bitOffset, 8)
        XCTAssertEqual(layout.rx?.bitOffset, 16, "Z")
        XCTAssertEqual(layout.ry?.bitOffset, 24, "Rz")
        XCTAssertEqual(layout.hat, field(32, 4, 0, 7))
        XCTAssertEqual(layout.buttonBitOffset, 40, "after the hat nibble and its 4-bit pad")
        XCTAssertEqual(layout.buttonCount, 10)
        XCTAssertNil(layout.lt)
        XCTAssertNil(layout.rt)
    }

    func testAReportIdIsDetectedAndOffsetsAreRelativeToThePayloadAfterIt() throws {
        let layout = try XCTUnwrap(HidGamepadLayout.parse(descriptor: HidDescriptors.reportId))
        XCTAssertEqual(layout.reportId, 3)
        XCTAssertEqual(layout.lx?.bitOffset, 0)
        XCTAssertEqual(layout.ly?.bitOffset, 8)
    }

    func testTheFirstReportCarryingFieldsLocksTheLayout() throws {
        let layout = try XCTUnwrap(HidGamepadLayout.parse(descriptor: HidDescriptors.adapter2))
        XCTAssertEqual(layout.reportId, 1, "the vendor report 2 that follows is not mixed in")
        XCTAssertEqual(layout.buttonCount, 15)
        XCTAssertEqual(layout.hat?.bitOffset, 16)
    }

    func testANonGamepadDescriptorIsRejected() {
        let vendor: [UInt8] = [0x06, 0x00, 0xFF, 0x09, 0x01, 0xA1, 0x01, 0x75, 0x08, 0x95, 0x01, 0x81, 0x02, 0xC0]
        XCTAssertNil(HidGamepadLayout.parse(descriptor: vendor))
    }

    func testAnEmptyDescriptorIsRejected() {
        XCTAssertNil(HidGamepadLayout.parse(descriptor: []))
    }

    func testATruncatedItemStopsTheWalkWithoutOverrunning() {
        XCTAssertNil(HidGamepadLayout.parse(descriptor: [0x26]), "a prefix that promises two bytes and supplies none")
        let cutAfterTheAxes = Array(HidDescriptors.gamepad.prefix(28))
        let layout = HidGamepadLayout.parse(descriptor: cutAfterTheAxes)
        XCTAssertNotNil(layout?.lx, "what was read before the cut stands")
        XCTAssertNil(layout?.hat)
    }

    func testALongItemIsSteppedOverWhole() throws {
        let longItem: [UInt8] = [0xFE, 0x02, 0x10, 0xAA, 0xBB]
        let layout = try XCTUnwrap(HidGamepadLayout.parse(descriptor: longItem + HidDescriptors.reportId))
        XCTAssertEqual(layout.reportId, 3)
        XCTAssertNil(HidGamepadLayout.parse(descriptor: [0xFE]), "a long item cut at its length byte")
    }

    func testAReservedItemIsIgnored() throws {
        let reservedBetween: [UInt8] = [
            0x05, 0x01, 0x0D, 0x09, 0x09, 0x30, 0x15, 0x00, 0x26, 0xFF, 0x00, 0x75, 0x08, 0x95, 0x01, 0x81, 0x02
        ]
        let layout = try XCTUnwrap(HidGamepadLayout.parse(descriptor: reservedBetween))
        XCTAssertEqual(layout.lx?.bitOffset, 0, "read as a Usage Page it would have made X a button")
        XCTAssertEqual(layout.buttonCount, 0)
    }

    func testAWideAxisKeepsItsThirtyTwoBits() throws {
        let layout = try XCTUnwrap(HidGamepadLayout.parse(descriptor: HidDescriptors.wideAxis))
        XCTAssertEqual(layout.lx, field(0, 32, 0, Int32.max))
    }

    func testAOneByteMaximumOverANonNegativeMinimumIsUnsigned() throws {
        let layout = try XCTUnwrap(HidGamepadLayout.parse(descriptor: HidDescriptors.oneByteMaximum))
        XCTAssertEqual(layout.lx?.logicalMax, 255, "Linux hid-core's reading: a sign-extended -1 would leave no range")
    }

    func testAOneByteMaximumOverANegativeMinimumKeepsItsSign() throws {
        let layout = try XCTUnwrap(HidGamepadLayout.parse(descriptor: HidDescriptors.signedOneByte))
        XCTAssertEqual(layout.lx?.logicalMin, -127)
        XCTAssertEqual(layout.lx?.logicalMax, 127)
    }

    func testFourByteBoundsAreReadAsTheirBitPattern() throws {
        let layout = try XCTUnwrap(HidGamepadLayout.parse(descriptor: HidDescriptors.signed32Axes))
        XCTAssertEqual(layout.lx, field(0, 32, Int32.min, Int32.max))
        XCTAssertEqual(layout.ly?.bitOffset, 32)
    }

    func testTheSwitchOrderPadParsesToTheExpectedFieldMap() throws {
        let layout = try XCTUnwrap(HidGamepadLayout.parse(descriptor: HidDescriptors.switchOrder))
        XCTAssertEqual(layout.reportId, 0)
        XCTAssertEqual(layout.buttonBitOffset, 0)
        XCTAssertEqual(layout.buttonCount, 14)
        XCTAssertEqual(layout.hat?.bitOffset, 16)
        XCTAssertEqual(layout.hat?.bitSize, 4)
        XCTAssertEqual([layout.lx?.bitOffset, layout.ly?.bitOffset, layout.rx?.bitOffset, layout.ry?.bitOffset], [24, 32, 40, 48])
        XCTAssertNil(layout.lt)
        XCTAssertNil(layout.rt)
    }

    func testTheM30ParsesToItsFieldMapWithAcceleratorAndBrakeAsTriggers() throws {
        let layout = try XCTUnwrap(HidGamepadLayout.parse(descriptor: HidDescriptors.m30, order: .eightBitDo))
        XCTAssertEqual(layout.reportId, 0)
        XCTAssertEqual(layout.buttonCount, 15)
        XCTAssertEqual(layout.buttonBitOffset, 0)
        XCTAssertEqual(layout.hat?.bitOffset, 16)
        XCTAssertEqual([layout.lx?.bitOffset, layout.ly?.bitOffset, layout.rx?.bitOffset, layout.ry?.bitOffset], [24, 32, 40, 48])
        XCTAssertEqual(layout.rt?.bitOffset, 56, "Accelerator, 0xC4")
        XCTAssertEqual(layout.lt?.bitOffset, 64, "Brake, 0xC5")
        XCTAssertEqual(layout.order, .eightBitDo)
    }

    func testThePsClassicParsesToTenButtonsAndTwoThreeStateAxes() throws {
        let layout = try XCTUnwrap(HidGamepadLayout.parse(descriptor: HidDescriptors.psClassic, order: .playStationClassic))
        XCTAssertEqual(layout.reportId, 0)
        XCTAssertEqual(layout.buttonCount, 10)
        XCTAssertEqual(layout.lx, field(10, 2, 0, 2))
        XCTAssertEqual(layout.ly?.bitOffset, 12)
        XCTAssertNil(layout.hat)
    }

    func testTheOrderIsTheCallersAndDefaultsToWestern() throws {
        XCTAssertEqual(try XCTUnwrap(HidGamepadLayout.parse(descriptor: HidDescriptors.switchOrder)).order, .western)
    }

    func testAButtonRunIsCappedAtSixteenAndOnlyTheFirstRunCounts() throws {
        let buttons: [UInt8] = [
            0x05, 0x09, 0x19, 0x01, 0x29, 0x20, 0x75, 0x01, 0x95, 0x20, 0x81, 0x02,
            0x95, 0x08, 0x81, 0x02
        ]
        let layout = try XCTUnwrap(HidGamepadLayout.parse(descriptor: buttons))
        XCTAssertEqual(layout.buttonCount, 16)
        XCTAssertEqual(layout.buttonBitOffset, 0)
    }

    func testAListOfUsagesRepeatsItsLastEntryAndTheFirstDeclarationWins() throws {
        let axes: [UInt8] = [
            0x05, 0x01, 0x09, 0x30, 0x09, 0x31, 0x15, 0x00, 0x26, 0xFF, 0x00, 0x75, 0x08, 0x95, 0x03, 0x81, 0x02,
            0x09, 0x30, 0x95, 0x01, 0x81, 0x02
        ]
        let layout = try XCTUnwrap(HidGamepadLayout.parse(descriptor: axes))
        XCTAssertEqual(layout.lx?.bitOffset, 0, "the second X is ignored")
        XCTAssertEqual(layout.ly?.bitOffset, 8, "the repeated Y at bit 16 is ignored")
    }

    func testAnItemWithFieldsButNoUsageDeclaresNothing() {
        let anonymous: [UInt8] = [0x05, 0x01, 0x15, 0x00, 0x26, 0xFF, 0x00, 0x75, 0x08, 0x95, 0x02, 0x81, 0x02]
        XCTAssertNil(HidGamepadLayout.parse(descriptor: anonymous))
    }
}
