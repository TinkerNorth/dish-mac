// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import XCTest
@testable import DishCore

/// Every plaintext the dish sends, against the fixtures the three sibling
/// clients pin (Wolf's input-data.adoc layouts, a live Sunshine's reading of
/// the arrival struct).
final class MoonlightInputTests: XCTestCase {

    func testControllerMultiWithTheAButtonOnPadZero() {
        let frame = MoonlightInput.PadFrame(controller: 0, activeMask: 1, buttons: MoonlightButton.buttonA)
        XCTAssertEqual(
            hexString(MoonlightInput.controllerMulti(frame)),
            "060222000000001e0c0000001a000000010014000010000000000000000000009c0000005500"
        )
        XCTAssertEqual(MoonlightInput.controllerMulti(frame).count, MoonlightProtocol.controllerMultiLength)
    }

    func testControllerMultiSplitsTheButtonFieldAndCarriesEveryAxis() {
        let frame = MoonlightInput.PadFrame(
            controller: 2,
            activeMask: 0b0101,
            buttons: MoonlightButton.touchpad | MoonlightButton.home | MoonlightButton.buttonY,
            leftTrigger: 0x7F,
            rightTrigger: 0xFF,
            leftX: -32768,
            leftY: 32767,
            rightX: -1,
            rightY: 256
        )
        let bytes = [UInt8](MoonlightInput.controllerMulti(frame))
        XCTAssertEqual(Array(bytes[14 ..< 16]), [0x02, 0x00], "controller")
        XCTAssertEqual(Array(bytes[16 ..< 18]), [0x05, 0x00], "active mask")
        XCTAssertEqual(Array(bytes[20 ..< 22]), [0x00, 0x84], "low word: home 0x0400 | y 0x8000")
        XCTAssertEqual(Array(bytes[22 ..< 24]), [0x7F, 0xFF], "triggers")
        XCTAssertEqual(Array(bytes[24 ..< 32]), [0x00, 0x80, 0xFF, 0x7F, 0xFF, 0xFF, 0x00, 0x01], "sticks little-endian")
        XCTAssertEqual(Array(bytes[34 ..< 36]), [0x10, 0x00], "high word: touchpad 0x100000 >> 16")
    }

    func testAnUnplugIsAMultiWithThePadsBitClearedFromTheMask() {
        let bytes = [UInt8](MoonlightInput.controllerMulti(MoonlightInput.PadFrame(controller: 1, activeMask: 0b0001)))
        XCTAssertEqual(Array(bytes[14 ..< 18]), [0x01, 0x00, 0x01, 0x00], "pad 1 named, only pad 0 left in the mask")
    }

    func testControllerArrivalIsTwentyBytesWithAnEightByteBody() {
        let xbox = MoonlightInput.PadArrival(
            controller: 0,
            type: MoonlightControllerType.xbox,
            capabilities: 0x03,
            supportedButtons: 0xFFFF
        )
        XCTAssertEqual(hexString(MoonlightInput.controllerArrival(xbox)), "060210000000000c0400005500010300ffff0000")
        let playStation = MoonlightInput.PadArrival(
            controller: 2, type: MoonlightControllerType.playStation, capabilities: 0x03, supportedButtons: 0xFFFF
        )
        XCTAssertEqual(hexString(MoonlightInput.controllerArrival(playStation)), "060210000000000c0400005502020300ffff0000")
        let full = MoonlightInput.PadArrival(
            controller: 1,
            type: MoonlightControllerType.nintendo,
            capabilities: 0xFF,
            supportedButtons: 0x0010_F7FF
        )
        XCTAssertEqual(hexString(MoonlightInput.controllerArrival(full)).suffix(16), "0103ff00fff71000", "the mask at offset 4 of the body")
    }

    func testControllerTouchMotionAndBatteryBodies() {
        XCTAssertEqual(
            hexString(MoonlightInput.controllerTouch(
                controller: 1,
                event: MoonlightTouchEvent.down,
                pointerId: 7,
                x: 0.5,
                y: 0.25,
                pressure: 1
            )),
            "06021c00000000180500005501010000070000000000003f0000803e0000803f"
        )
        XCTAssertEqual(
            hexString(MoonlightInput.controllerTouch(
                controller: 1,
                event: MoonlightTouchEvent.down,
                pointerId: 2,
                x: 0,
                y: 1,
                pressure: 1
            )),
            "06021c0000000018050000550101000002000000000000000000803f0000803f"
        )
        XCTAssertEqual(
            hexString(MoonlightInput.controllerMotion(controller: 2, type: MoonlightMotionType.gyro, x: 1, y: -1, z: 0.5)),
            "060218000000001406000055020200000000803f000080bf0000003f"
        )
        XCTAssertEqual(
            hexString(MoonlightInput.controllerBattery(controller: 0, state: MoonlightBatteryState.charging, percentage: 88)),
            "06020c00000000080700005500035800"
        )
        XCTAssertEqual(
            hexString(MoonlightInput.controllerBattery(controller: 0, state: MoonlightBatteryState.charging, percentage: 42)),
            "06020c00000000080700005500032a00"
        )
    }

    func testMouseMessagesCarryBigEndianDeltas() {
        XCTAssertEqual(hexString(MoonlightInput.mouseMoveRel(deltaX: -1, deltaY: 0)), "06020c000000000807000000ffff0000")
        XCTAssertEqual(
            hexString(MoonlightInput.mouseButton(down: true, button: MoonlightMouseButton.left)),
            "060209000000000508000000" + "01"
        )
        XCTAssertEqual(
            hexString(MoonlightInput.mouseButton(down: false, button: MoonlightMouseButton.right)),
            "060209000000000509000000" + "03"
        )
        XCTAssertEqual(hexString(MoonlightInput.mouseScroll(amount: 120)), "06020e000000000a0a000000007800780000")
        XCTAssertEqual(hexString(MoonlightInput.mouseScroll(amount: -120)), "06020e000000000a0a000000ff88ff880000")
    }

    /// The keepalive as Wolf captured it from a real client, the same bytes
    /// every sibling's seal test uses as its seq-2 vector.
    func testThePeriodicPingIsTheCapturedTwelveByteForm() {
        XCTAssertEqual(hexString(MoonlightInput.periodicPing()), "000208000400000000000000")
        XCTAssertEqual(MoonlightInput.periodicPing().count, MoonlightProtocol.periodicPingLength)
    }

    /// Wolf's control.hpp: TERMINATION is 0x0109, reason big-endian.
    func testTheTerminationNamesWolfsTypeAndTheGracefulReason() {
        XCTAssertEqual(hexString(MoonlightInput.termination()), "0901040080030023")
        XCTAssertEqual(MoonlightProtocol.packetTermination, 0x0109)
        XCTAssertEqual(MoonlightProtocol.packetTerminationLegacy, 0x0100, "the docs' value, still decoded")
    }

    func testEveryMessageIsItsDeclaredLength() {
        XCTAssertEqual(MoonlightInput.controllerArrival(.init(controller: 0, type: 1, capabilities: 0, supportedButtons: 0)).count, 20)
        XCTAssertEqual(MoonlightInput.controllerTouch(controller: 0, event: 1, pointerId: 0, x: 0, y: 0, pressure: 0).count, 32)
        XCTAssertEqual(MoonlightInput.controllerMotion(controller: 0, type: 1, x: 0, y: 0, z: 0).count, 28)
        XCTAssertEqual(MoonlightInput.controllerBattery(controller: 0, state: 0, percentage: 0).count, 16)
        XCTAssertEqual(MoonlightInput.mouseMoveRel(deltaX: 0, deltaY: 0).count, 16)
        XCTAssertEqual(MoonlightInput.mouseButton(down: true, button: 1).count, 13)
        XCTAssertEqual(MoonlightInput.mouseScroll(amount: 0).count, 18)
        XCTAssertEqual(MoonlightInput.termination().count, 8)
    }

    func testTheWrapperSizeCountsFromTheInputTypeToTheEnd() {
        let bytes = [UInt8](MoonlightInput.controllerTouch(controller: 0, event: 1, pointerId: 0, x: 0, y: 0, pressure: 0))
        XCTAssertEqual(Array(bytes[2 ..< 4]), [0x1C, 0x00], "control length 28 = 32 - 4")
        XCTAssertEqual(Array(bytes[4 ..< 8]), [0x00, 0x00, 0x00, 0x18], "data size 24 = 32 - 8, big-endian")
    }
}
