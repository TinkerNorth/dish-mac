// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import XCTest

/// The 2015 Steam Controller's vendor packets, quiet and restore reports and
/// receiver events: the desktops' `test_usb_report_parsers.cpp` cases, which
/// mirror dish-android's hardware-verified vectors, one for one.
final class SteamControllerTests: XCTestCase {

    private enum Button {
        static let rightTriggerClick: UInt32 = 0x000001
        static let leftTriggerClick: UInt32 = 0x000002
        static let rightBumper: UInt32 = 0x000004
        static let leftBumper: UInt32 = 0x000008
        static let north: UInt32 = 0x000010
        static let east: UInt32 = 0x000020
        static let west: UInt32 = 0x000040
        static let south: UInt32 = 0x000080
        static let dpadUp: UInt32 = 0x000100
        static let dpadRight: UInt32 = 0x000200
        static let menu: UInt32 = 0x001000
        static let guide: UInt32 = 0x002000
        static let escape: UInt32 = 0x004000
        static let backLeft: UInt32 = 0x008000
        static let backRight: UInt32 = 0x010000
        static let leftPadClicked: UInt32 = 0x020000
        static let rightPadClicked: UInt32 = 0x040000
        static let leftPadFinger: UInt32 = 0x080000
        static let rightPadFinger: UInt32 = 0x100000
        static let stickButton: UInt32 = 0x400000
        static let leftPadAndStick: UInt32 = 0x800000
    }

    private struct NotAStatePacket: Error {}

    private func state(_ packet: SteamPacketBytes, hold: inout SteamStickHold) throws -> (GamepadReport, MotionSample?) {
        guard case let .state(report, motion) = packet.decode(hold: &hold) else {
            XCTFail("not a state packet")
            throw NotAStatePacket()
        }
        return (report, motion)
    }

    private func report(_ packet: SteamPacketBytes) throws -> GamepadReport {
        var hold = SteamStickHold()
        return try XCTUnwrap(stateReport(packet.decode(hold: &hold)))
    }

    private func stateReport(_ reading: SteamReading?) -> GamepadReport? {
        guard case let .state(report, _) = reading else { return nil }
        return report
    }

    // MARK: - State packets

    func testAShortWrongVersionOrWrongTypePacketIsNotAState() {
        var short = SteamPacketBytes.state()
        short.bytes.removeLast(17)
        XCTAssertNil(short.decodeFresh(), "47 bytes")
        var badVersion = SteamPacketBytes.state()
        badVersion.bytes[0] = 0x02
        XCTAssertNil(badVersion.decodeFresh())
        var wirelessType = SteamPacketBytes.state()
        wirelessType.bytes[2] = 0x03
        XCTAssertNil(wirelessType.decodeFresh(), "the receiver's type with a state's length is neither")
    }

    func testFaceAndShoulderButtonsMapByPosition() throws {
        let face = try report(.state(Button.south | Button.east | Button.west | Button.north))
        XCTAssertEqual(face.buttons, WireButtonWord([.faceA, .faceB, .faceX, .faceY]).rawValue)
        let shoulders = try report(.state(Button.leftBumper | Button.rightBumper))
        XCTAssertEqual(shoulders.buttons, WireButtonWord([.leftShoulder, .rightShoulder]).rawValue)
    }

    func testMenuEscapeAndGuideMapToBackStartAndGuide() throws {
        let buttons = try report(.state(Button.menu | Button.escape | Button.guide)).buttons
        XCTAssertEqual(buttons, WireButtonWord([.back, .start, .guide]).rawValue)
    }

    func testTheDpadBitsMapDirectly() throws {
        let buttons = try report(.state(Button.dpadUp | Button.dpadRight)).buttons
        XCTAssertEqual(buttons, WireButtonWord([.dpadUp, .dpadRight]).rawValue)
    }

    func testTheTriggersScaleAndSaturateBeforeTheRawRail() throws {
        var packet = SteamPacketBytes.state()
        packet.bytes[12] = 100
        let partial = try report(packet)
        XCTAssertEqual(partial.lt, 0)
        XCTAssertEqual(partial.rt, 126)
        packet.bytes[11] = 202
        packet.bytes[12] = 255
        let full = try report(packet)
        XCTAssertEqual(full.lt, 255, "Valve's full scale is 26000 of a possible 32895")
        XCTAssertEqual(full.rt, 255)
    }

    // MARK: - The shared left axes

    func testTheLeftAxesAreTheStickWhenNoFingerIsOnThePad() throws {
        var packet = SteamPacketBytes.state()
        packet.setLe16(16, -8000)
        packet.setLe16(18, 12000)
        let stick = try report(packet)
        XCTAssertEqual(stick.lx, -8000)
        XCTAssertEqual(stick.ly, 12000, "the pad is up-positive, as the wire is")
    }

    func testTheStickHoldsItsValueAcrossAnInterleavedPadFrame() throws {
        var hold = SteamStickHold()
        var stickFrame = SteamPacketBytes.state()
        stickFrame.setLe16(16, 5000)
        stickFrame.setLe16(18, -6000)
        _ = try state(stickFrame, hold: &hold) // The frame only seeds the hold.
        var padFrame = SteamPacketBytes.state(Button.leftPadFinger | Button.leftPadAndStick)
        padFrame.setLe16(16, 30000)
        padFrame.setLe16(18, 30000)
        let (next, _) = try state(padFrame, hold: &hold)
        XCTAssertEqual(next.lx, 5000)
        XCTAssertEqual(next.ly, -6000)
    }

    func testTheStickCentresWhenThePadTakesOverWithoutInterleaving() throws {
        var hold = SteamStickHold()
        var stickFrame = SteamPacketBytes.state()
        stickFrame.setLe16(16, 5000)
        _ = try state(stickFrame, hold: &hold) // The frame only seeds the hold.
        var padFrame = SteamPacketBytes.state(Button.leftPadFinger)
        padFrame.setLe16(16, 30000)
        let (next, _) = try state(padFrame, hold: &hold)
        XCTAssertEqual(next.lx, 0)
        XCTAssertEqual(next.ly, 0)
    }

    func testTheLeftAxesFollowTheFingerAndTheInterleaveBits() {
        XCTAssertEqual(steamLeftAxes(fingerOnPad: false, interleaved: false), .stick)
        XCTAssertEqual(steamLeftAxes(fingerOnPad: false, interleaved: true), .stick)
        XCTAssertEqual(steamLeftAxes(fingerOnPad: true, interleaved: false), .pad)
        XCTAssertEqual(steamLeftAxes(fingerOnPad: true, interleaved: true), .padBesideStick)
    }

    func testALeftPadClickIsAStickClickWhileThePadIsIdle() throws {
        let idle = try report(.state(Button.leftPadClicked))
        XCTAssertEqual(idle.buttons, WireButton.leftThumb.bit)
        XCTAssertEqual(idle.extButtons, 0, "the stick's click alone")
    }

    func testALeftPadClickUnderAFingerIsTheLeftPadClickAndNotTheStickClick() throws {
        let onPad = try report(.state(Button.leftPadClicked | Button.leftPadFinger))
        XCTAssertEqual(onPad.buttons, 0, "a finger on the pad owns the click")
        XCTAssertEqual(onPad.extButtons, ProtocolConstants.extButtonLeftPadClick)
    }

    func testTheStickAndRightPadClicksAreTheThumbButtons() throws {
        let buttons = try report(.state(Button.stickButton | Button.rightPadClicked)).buttons
        XCTAssertEqual(buttons, WireButtonWord([.leftThumb, .rightThumb]).rawValue)
    }

    func testTheRightPadClickStaysTheRightStickClickAloneWhileThePadIsTheStick() throws {
        let clicked = try report(.state(Button.rightPadClicked | Button.rightPadFinger))
        XCTAssertEqual(clicked.buttons, WireButton.rightThumb.bit)
        XCTAssertEqual(clicked.extButtons, 0, "one wire field per click")
    }

    // MARK: - The extras on the extended-buttons word

    func testTheGripsAreSdlsLeftAndRightPaddle() throws {
        let leftGrip = try report(.state(Button.backLeft))
        XCTAssertEqual(leftGrip.extButtons, ProtocolConstants.extButtonLeftPaddle1)
        XCTAssertEqual(leftGrip.buttons, 0, "a grip presses no XUSB button")
        XCTAssertEqual(try report(.state(Button.backRight)).extButtons, ProtocolConstants.extButtonRightPaddle1)
    }

    func testTheFullPullTriggerBitsAreTheTriggerClicks() throws {
        XCTAssertEqual(try report(.state(Button.leftTriggerClick)).extButtons, ProtocolConstants.extButtonLeftTriggerClick)
        XCTAssertEqual(try report(.state(Button.rightTriggerClick)).extButtons, ProtocolConstants.extButtonRightTriggerClick)
    }

    func testTheMappedButtonsLeaveTheWordClear() throws {
        let everyMapped = Button.south | Button.east | Button.west | Button.north | Button.leftBumper | Button.rightBumper
            | Button.menu | Button.escape | Button.guide | Button.dpadUp | Button.dpadRight | Button.stickButton | Button.rightPadClicked
        XCTAssertEqual(try report(.state(everyMapped)).extButtons, 0)
    }

    func testEveryExtraRidesTheWordAtOnce() throws {
        let extras = Button.backLeft | Button.backRight | Button.leftTriggerClick | Button.rightTriggerClick
            | Button.leftPadClicked | Button.leftPadFinger
        let expected = ProtocolConstants.extButtonLeftPaddle1 | ProtocolConstants.extButtonRightPaddle1
            | ProtocolConstants.extButtonLeftTriggerClick | ProtocolConstants.extButtonRightTriggerClick
            | ProtocolConstants.extButtonLeftPadClick
        XCTAssertEqual(try report(.state(extras)).extButtons, expected)
    }

    // MARK: - The right pad as the right stick

    func testTheRightPadDrivesTheRightStickThroughTheShellRotation() throws {
        var packet = SteamPacketBytes.state(Button.rightPadFinger)
        packet.setLe16(20, 10000)
        let rotated = try report(packet)
        XCTAssertEqual(rotated.rx, 9659)
        XCTAssertEqual(rotated.ry, 2588)
    }

    func testTheRightStickRecentresWhenTheFingerLifts() throws {
        var held = SteamPacketBytes.state(Button.rightPadFinger)
        held.setLe16(20, 20000)
        held.setLe16(22, 20000)
        XCTAssertNotEqual(try report(held).rx, 0)
        var lifted = held
        lifted.bytes[10] = 0
        let next = try report(lifted)
        XCTAssertEqual(next.rx, 0)
        XCTAssertEqual(next.ry, 0)
    }

    // MARK: - Motion

    func testTheImuRotatesOntoTheWireAxisOrderAndScale() throws {
        var packet = SteamPacketBytes.state()
        for (offset, value) in [(28, 1000), (30, 2000), (32, 3000), (34, 4000), (36, 5000), (38, 6000)] {
            packet.setLe16(offset, Int16(value))
        }
        var hold = SteamStickHold()
        let (_, motion) = try state(packet, hold: &hold)
        XCTAssertEqual(motion, MotionSample(gyroX: 3999, gyroY: 5999, gyroZ: 4999, accelX: 499, accelY: 1499, accelZ: -999))
    }

    func testASilentImuBlockPublishesNoMotion() throws {
        var hold = SteamStickHold()
        let (_, motion) = try state(.state(Button.south), hold: &hold)
        XCTAssertNil(motion, "an all-zero block means the IMU setting never took")
    }

    // MARK: - The receiver's events

    func testWirelessConnectAndDisconnectEventsClassify() {
        XCTAssertEqual(SteamPacketBytes.wireless(0x01).decodeFresh(), .link(.disconnected))
        XCTAssertEqual(SteamPacketBytes.wireless(0x02).decodeFresh(), .link(.connected))
    }

    func testAStatePacketIsNotAWirelessEvent() {
        let reading = SteamPacketBytes.state(Button.south).decodeFresh()
        XCTAssertEqual(stateReport(reading)?.buttons, WireButton.faceA.bit)
    }

    func testAMalformedWirelessEventIsNothing() {
        var short = SteamPacketBytes.wireless(0x02)
        short.bytes.removeLast(60)
        XCTAssertNil(short.decodeFresh(), "four bytes")
        var badVersion = SteamPacketBytes.wireless(0x02)
        badVersion.bytes[0] = 0x02
        XCTAssertNil(badVersion.decodeFresh())
        var badLength = SteamPacketBytes.wireless(0x02)
        badLength.bytes[3] = 0x02
        XCTAssertNil(badLength.decodeFresh())
        XCTAssertNil(SteamPacketBytes.wireless(0x03).decodeFresh(), "a newly paired pad is not a connect here")
        var status = SteamPacketBytes.wireless(0x02)
        status.bytes[2] = 0x04
        XCTAssertNil(status.decodeFresh(), "the status packet shares the endpoint")
    }

    // MARK: - Feature reports

    func testTheQuietSequenceClearsMappingsThenWritesSettings() {
        let reports = steamConfigReports(.quiet)
        XCTAssertEqual(reports.map(\.count), [64, 64], "each a whole feature report, id 0 carries no id byte")
        guard reports.count == 2 else { return }
        XCTAssertEqual(Array(reports[0].prefix(2)), [0x81, 0x00])
        XCTAssertEqual(Array(reports[1].prefix(11)), [0x87, 0x09, 0x07, 0x07, 0x00, 0x08, 0x07, 0x00, 0x30, 0x18, 0x00])
        XCTAssertTrue(reports.allSatisfy { $0.dropFirst(11).allSatisfy { $0 == 0 } }, "zero-padded")
    }

    func testTheRestoreSequencePutsTheKeyboardAndMouseBack() {
        let reports = steamConfigReports(.restore)
        XCTAssertEqual(reports.map(\.count), [64, 64, 64])
        guard reports.count == 3 else { return }
        XCTAssertEqual(Array(reports[0].prefix(2)), [0x85, 0x00])
        XCTAssertEqual(Array(reports[1].prefix(2)), [0x8E, 0x00])
        XCTAssertEqual(Array(reports[2].prefix(5)), [0x87, 0x03, 0x08, 0x00, 0x00], "the right pad's mouse, by name")
    }

    func testTheReceiversStateRequestIsAWholeFeatureReport() {
        let request = steamReceiverStateRequest()
        XCTAssertEqual(request.count, 64)
        XCTAssertEqual(Array(request.prefix(2)), [0xB4, 0x00])
        XCTAssertTrue(request.dropFirst(2).allSatisfy { $0 == 0 })
    }
}
