// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import XCTest

/// An Xbox 360 pad's vendor interface: its input report and its rumble
/// report under dish-android's `usb_parsers_test.cpp` XINPUT_360 fixtures,
/// the endpoints its reports and its rumble ride (SDL's libusb rule), and
/// the interface triple it is matched on.
final class XusbReportTests: XCTestCase {

    /// Type 0x00, length 0x14, no buttons, the sticks at rest.
    private static let idle: [UInt8] = [0x00, 0x14] + [UInt8](repeating: 0, count: 18)

    private static let interruptIn = UsbEndpoint(address: 0x81, attributes: 0x03, maxPacketSize: 32)
    private static let interruptOut = UsbEndpoint(address: 0x01, attributes: 0x03, maxPacketSize: 32)

    private func decode(_ bytes: [UInt8]) -> GamepadReport? {
        bytes.withUnsafeBufferPointer(decodeXusbReport)
    }

    private func setting(_ offset: Int, to value: Int16, in bytes: [UInt8]) -> [UInt8] {
        let word = UInt16(bitPattern: value)
        var set = bytes
        set[offset] = UInt8(truncatingIfNeeded: word)
        set[offset + 1] = UInt8(truncatingIfNeeded: word >> 8)
        return set
    }

    // MARK: - The input report

    func testEveryButtonBitMapsToItsXusbBit() {
        let rows: [(byte: Int, bit: UInt8, button: WireButton)] = [
            (2, 0x01, .dpadUp), (2, 0x02, .dpadDown), (2, 0x04, .dpadLeft), (2, 0x08, .dpadRight),
            (2, 0x10, .start), (2, 0x20, .back), (2, 0x40, .leftThumb), (2, 0x80, .rightThumb),
            (3, 0x01, .leftShoulder), (3, 0x02, .rightShoulder), (3, 0x04, .guide),
            (3, 0x10, .faceA), (3, 0x20, .faceB), (3, 0x40, .faceX), (3, 0x80, .faceY)
        ]
        for row in rows {
            var bytes = Self.idle
            bytes[row.byte] = row.bit
            XCTAssertEqual(decode(bytes)?.buttons, row.button.bit, "byte \(row.byte) bit \(row.bit)")
        }
    }

    func testTheButtonWordsUnassignedBitNeverPressesMicMute() {
        var bytes = Self.idle
        bytes[3] = 0x08
        XCTAssertEqual(decode(bytes)?.buttons, 0, "a 360 pad has no mic-mute button")
    }

    func testTriggersAreRawBytesAndSticksAreLittleEndianAndUpPositive() {
        var bytes = Self.idle
        bytes[4] = 0x7F
        bytes[5] = 0xFF
        bytes = setting(6, to: -32768, in: bytes)
        bytes = setting(8, to: 32767, in: bytes)
        bytes = setting(10, to: -1, in: bytes)
        bytes = setting(12, to: 1, in: bytes)
        XCTAssertEqual(decode(bytes), GamepadReport(lt: 127, rt: 255, lx: -32768, ly: 32767, rx: -1, ry: 1))
    }

    func testTheIdleReportIsTheReleasedState() {
        XCTAssertEqual(decode(Self.idle), .released)
    }

    func testEveryButtonHeldLeavesTheExtendedButtonsWordEmpty() {
        var bytes = Self.idle
        bytes[2] = 0xFF
        bytes[3] = 0xFF
        let decoded = decode(bytes)
        XCTAssertEqual(decoded?.buttons, ~WireButton.micMute.bit)
        XCTAssertEqual(decoded?.extButtons, 0, "XUSB carries no paddles and no Capture")
    }

    func testAReportAsLongAsTheSticksDecodesWhateverItsLengthByteSays() {
        var bytes = [UInt8](repeating: 0, count: 14)
        bytes[3] = 0x04
        XCTAssertEqual(decode(bytes)?.buttons, WireButton.guide.bit, "dish-android's 14-byte fixture, length byte zero")
    }

    func testAShortReportOrAnotherReportTypeIsIgnored() {
        XCTAssertNil(decode(Array(Self.idle.prefix(13))))
        var led = Self.idle
        led[0] = 0x01
        XCTAssertNil(decode(led), "the LED status report")
        XCTAssertNil(decode([0x03, 0x03, 0x00]), "the rumble status report")
        XCTAssertNil(decode([]))
    }

    // MARK: - Rumble

    func testTheRumbleReportCarriesEachMotorsHighByte() {
        XCTAssertEqual(xusbRumbleReport(strong: 0xFF00, weak: 0x8000), [0x00, 0x08, 0x00, 0xFF, 0x80, 0x00, 0x00, 0x00])
    }

    func testACommandHoldsForItsDurationUpToTheSafetyNet() {
        let command = xusbRumbleCommand(strong: 0x8000, weak: 0x1000, durationMs: 500)
        XCTAssertEqual(command.report, xusbRumbleReport(strong: 0x8000, weak: 0x1000))
        XCTAssertEqual(command.holdMs, 500)
        XCTAssertEqual(xusbRumbleCommand(strong: 0x8000, weak: 0, durationMs: 0).holdMs, TritonRumbleRule.maxHoldMs, "a continuous command")
        XCTAssertEqual(xusbRumbleCommand(strong: 0, weak: 0x8000, durationMs: 9000).holdMs, TritonRumbleRule.maxHoldMs)
    }

    func testAStillCommandIsTheStopAndHoldsNothing() {
        let stop = xusbRumbleCommand(strong: 0, weak: 0, durationMs: 500)
        XCTAssertEqual(stop.report, xusbRumbleStop)
        XCTAssertEqual(xusbRumbleStop, [0x00, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        XCTAssertNil(stop.holdMs)
    }

    // MARK: - The interface

    func testThe360PadsPairIsItsInputAndItsRumble() {
        XCTAssertEqual(
            xusbEndpoints([Self.interruptIn, Self.interruptOut]),
            XusbEndpoints(input: Self.interruptIn, output: Self.interruptOut)
        )
    }

    func testTheFirstInterruptEndpointOfEachDirectionIsTaken() {
        let bulkIn = UsbEndpoint(address: 0x82, attributes: 0x02, maxPacketSize: 64)
        let laterIn = UsbEndpoint(address: 0x83, attributes: 0x03, maxPacketSize: 32)
        let laterOut = UsbEndpoint(address: 0x02, attributes: 0x03, maxPacketSize: 32)
        let found = xusbEndpoints([bulkIn, Self.interruptOut, Self.interruptIn, laterIn, laterOut])
        XCTAssertEqual(found, XusbEndpoints(input: Self.interruptIn, output: Self.interruptOut))
    }

    func testWithoutAnInterruptInThereIsNothingToRead() {
        XCTAssertNil(xusbEndpoints([Self.interruptOut]))
        XCTAssertNil(xusbEndpoints([]))
    }

    func testWithoutAnInterruptOutThePadIsReadWithNoRumble() {
        XCTAssertEqual(xusbEndpoints([Self.interruptIn]), XusbEndpoints(input: Self.interruptIn, output: nil))
    }

    func testTheWiredPadsVendorInterfaceIsFF5D01() {
        XCTAssertTrue(isXusbInterface(interfaceClass: 0xFF, subclass: 0x5D, interfaceProtocol: 0x01))
        XCTAssertFalse(isXusbInterface(interfaceClass: 0xFF, subclass: 0x5D, interfaceProtocol: 0x03), "the headset interface")
        XCTAssertFalse(isXusbInterface(interfaceClass: 0xFF, subclass: 0x5D, interfaceProtocol: 0x81), "the wireless receiver's frame")
        XCTAssertFalse(isXusbInterface(interfaceClass: 0xFF, subclass: 0xFD, interfaceProtocol: 0x13), "the security interface")
        XCTAssertFalse(isXusbInterface(interfaceClass: 0x03, subclass: 0x5D, interfaceProtocol: 0x01))
        XCTAssertFalse(isXusbInterface(interfaceClass: nil, subclass: nil, interfaceProtocol: nil))
    }
}
