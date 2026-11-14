// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import XCTest

/// The 2015 Steam Controller over Bluetooth LE as SDL reads it on macOS:
/// report 3's segments assembled into chunked state packets, read through the
/// wired pad's own mappings, and the feature reports that quiet it and give it
/// back, one segment each. The packets are built from SDL's
/// `UpdateBLESteamControllerState` and checked against the wired decoder
/// where the two links share a layout.
final class SteamControllerBleTests: XCTestCase {

    private enum Button {
        static let rightTriggerClick: UInt32 = 0x000001
        static let leftTriggerClick: UInt32 = 0x000002
        static let rightBumper: UInt32 = 0x000004
        static let north: UInt32 = 0x000010
        static let south: UInt32 = 0x000080
        static let dpadLeft: UInt32 = 0x000400
        static let menu: UInt32 = 0x001000
        static let guide: UInt32 = 0x002000
        static let backLeft: UInt32 = 0x008000
        static let backRight: UInt32 = 0x010000
        static let leftPadClicked: UInt32 = 0x020000
        static let rightPadClicked: UInt32 = 0x040000
        static let leftPadFinger: UInt32 = 0x080000
        static let rightPadFinger: UInt32 = 0x100000
        static let stickButton: UInt32 = 0x400000
    }

    /// SDL's messages, {id, payload length, payload}: `ResetSteamController`,
    /// `SetSensorsEnabled` and `CloseSteamController`.
    private enum SdlMessage {
        static let clearDigitalMappings: [UInt8] = [0x81, 0x00]
        static let loadDefaultSettings: [UInt8] = [0x8E, 0x00]
        /// Wireless packet version 2, both trackpads off, no smoothed mouse.
        static let resetSettings: [UInt8] = [0x87, 0x0C, 0x31, 0x02, 0x00, 0x07, 0x07, 0x00, 0x08, 0x07, 0x00, 0x18, 0x00, 0x00]
        static let rawImu: [UInt8] = [0x87, 0x03, 0x30, 0x18, 0x00]
        static let defaultDigitalMappings: [UInt8] = [0x85, 0x00]
        static let rightPadMouse: [UInt8] = [0x87, 0x03, 0x08, 0x00, 0x00]
    }

    private struct NotAStatePacket: Error {}

    private var carry = SteamBleCarry()

    /// A two-segment packet: 19 bytes of mask and chunks.
    private let twoSegments = SteamBlePacketBytes().buttons(0x80).triggers(left: 10, right: 20)
        .stick(x: 1, y: 2).leftPad(x: 3, y: 4).rightPad(x: 5, y: 6)

    private func decode(_ packet: SteamBlePacketBytes) -> SteamReading? {
        packet.decode(carry: &carry)
    }

    private func feed(_ report: [UInt8]) -> SteamReading? {
        decodeBleReport(report, carry: &carry)
    }

    private func state(_ packet: SteamBlePacketBytes) throws -> (GamepadReport, MotionSample?, SteamPads) {
        guard case let .state(report, motion, pads) = decode(packet) else {
            XCTFail("not a state packet")
            throw NotAStatePacket()
        }
        return (report, motion, pads)
    }

    private func report(_ packet: SteamBlePacketBytes) throws -> GamepadReport {
        try state(packet).0
    }

    private func oneSegment(_ message: [UInt8]) -> [UInt8] {
        [0x03, 0xC0] + message + [UInt8](repeating: 0, count: 18 - message.count)
    }

    // MARK: - What the chunks say

    func testButtonsTriggersGripsAndFullPullClicksReadAsTheWiredPadsDo() {
        let held = Button.south | Button.north | Button.rightBumper | Button.menu | Button.guide | Button.dpadLeft
            | Button.backLeft | Button.backRight | Button.leftTriggerClick | Button.rightTriggerClick
        var wired = SteamPacketBytes.state(held)
        wired.bytes[11] = 100
        wired.bytes[12] = 255
        let ble = SteamBlePacketBytes().buttons(held).triggers(left: 100, right: 255)
        XCTAssertEqual(decode(ble), wired.decodeFresh())
    }

    func testTheRightPadAndTheImuReadAsTheWiredPadsDoThroughTheShellRotation() {
        let held = Button.rightPadFinger | Button.rightPadClicked
        var wired = SteamPacketBytes.state(held)
        wired.setLe16(20, 9000)
        wired.setLe16(22, -4000)
        for (offset, value) in zip(stride(from: 28, through: 38, by: 2), [100, -200, 16384, -300, 400, 500] as [Int16]) {
            wired.setLe16(offset, value)
        }
        let ble = SteamBlePacketBytes().buttons(held).rightPad(x: 9000, y: -4000).accel(100, -200, 16384).gyro(-300, 400, 500)
        XCTAssertEqual(decode(ble), wired.decodeFresh())
    }

    func testTheLeftPadIsAChunkOfItsOwnAndLeavesTheStickWhereItIs() throws {
        let held = Button.leftPadFinger | Button.leftPadClicked
        var wired = SteamPacketBytes.state(held)
        wired.setLe16(16, 5000)
        wired.setLe16(18, 6000)
        guard case let .state(_, _, wiredPads) = wired.decodeFresh() else { return XCTFail("not a state packet") }
        let (report, _, pads) = try state(SteamBlePacketBytes().buttons(held).stick(x: -8000, y: 12000).leftPad(x: 5000, y: 6000))
        XCTAssertEqual(pads.left, wiredPads.left, "the wired pad's rotation, its click the pad's")
        XCTAssertTrue(pads.left.clicked)
        XCTAssertEqual(report.lx, -8000, "the stick keeps its own axes beside the pad")
        XCTAssertEqual(report.ly, 12000, "up-positive, as the wire is")
    }

    func testTheStickClickIsItsOwnBitAndALeftPadClickWithNoFingerIsNoStickClick() throws {
        XCTAssertEqual(try report(SteamBlePacketBytes().buttons(Button.stickButton)).buttons, WireButton.leftThumb.bit)
        let padClick = try state(SteamBlePacketBytes().buttons(Button.leftPadClicked))
        XCTAssertEqual(padClick.0.buttons, 0, "only the wired firmware sends a stick click as the pad's")
        XCTAssertFalse(padClick.2.left.clicked, "no finger, no pad")
    }

    func testAPadWhoseImuHasSaidNothingPublishesNoMotion() throws {
        XCTAssertNil(try state(SteamBlePacketBytes().buttons(Button.south)).1)
    }

    func testChunksAPacketLeavesOutKeepWhatTheyLastSaid() throws {
        XCTAssertNotNil(decode(SteamBlePacketBytes().buttons(Button.south).stick(x: 1000, y: 2000).accel(1, 2, 3).gyro(4, 5, 6)))
        let (report, motion, _) = try state(SteamBlePacketBytes().triggers(left: 255, right: 0))
        XCTAssertEqual(report.buttons, WireButton.faceA.bit)
        XCTAssertEqual(report.lx, 1000)
        XCTAssertEqual(report.ly, 2000)
        XCTAssertEqual(report.lt, 255)
        XCTAssertNotNil(motion, "the IMU as it last read")
    }

    func testTheChunksSdlSkipsAreSteppedOverSoTheNextLandWhereTheyAre() throws {
        let packet = SteamBlePacketBytes().buttons(Button.south).with(SteamBlePacketBytes.highButtons, [0xFF, 0xFF, 0xFF])
            .stick(x: 3000, y: -3000).with(SteamBlePacketBytes.quaternion, [UInt8](repeating: 0x7F, count: 8))
        let report = try report(packet)
        XCTAssertEqual(report.buttons, WireButton.faceA.bit, "the button word's top bytes press nothing")
        XCTAssertEqual(report.lx, 3000)
        XCTAssertEqual(report.ly, -3000)
    }

    func testAPacketOfAnotherTypeIsNoState() {
        var status = SteamBlePacketBytes().buttons(Button.south)
        status.type = 5
        XCTAssertNil(decode(status))
    }

    func testAPacketNamingMoreChunksThanItCarriesDoesNotDecodeOrMoveTheHeldState() throws {
        XCTAssertNotNil(decode(SteamBlePacketBytes().buttons(Button.south)))
        let named = SteamBlePacketBytes().buttons(Button.menu).triggers(left: 9, right: 9).stick(x: 9, y: 9)
            .leftPad(x: 9, y: 9).rightPad(x: 9, y: 9).accel(9, 9, 9).gyro(9, 9, 9)
        let firstAsLast = SteamBlePacketBytes.segment(number: 0, last: true, Array(named.packet.prefix(18)))
        XCTAssertNil(feed(firstAsLast))
        let report = try report(SteamBlePacketBytes().triggers(left: 0, right: 0))
        XCTAssertEqual(report.buttons, WireButton.faceA.bit, "the first packet's buttons still")
        XCTAssertEqual(report.lx, 0)
    }

    // MARK: - The segments

    func testAPacketOverTwoSegmentsDecodesOnceItsLastIsIn() {
        let reports = twoSegments.reports
        XCTAssertEqual(reports.count, 2)
        XCTAssertNil(feed(reports[0]))
        XCTAssertNotNil(feed(reports[1]))
    }

    func testASegmentOutOfTurnIsDroppedAndTheNextPacketStartsAfresh() {
        XCTAssertNil(feed(twoSegments.reports[1]), "a second segment with no first")
        XCTAssertNotNil(decode(twoSegments))
    }

    func testAFirstSegmentRestartsAPacketLeftUnfinished() throws {
        XCTAssertNil(feed(twoSegments.reports[0]))
        XCTAssertEqual(try report(SteamBlePacketBytes().buttons(Button.menu)).buttons, WireButton.back.bit)
    }

    func testASegmentWithoutItsDataFlagIsSkippedWithoutLosingTheAssembly() {
        XCTAssertNil(feed(twoSegments.reports[0]))
        XCTAssertNil(feed(SteamBlePacketBytes.segment(number: 0, last: true, [], carriesData: false)))
        XCTAssertNotNil(feed(twoSegments.reports[1]))
    }

    func testAnotherReportLeavesTheAssemblyAndAShortSegmentStartsItOver() {
        XCTAssertNil(feed(twoSegments.reports[0]))
        XCTAssertNil(feed([0x01, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00]), "its keyboard, while lizard mode lasts")
        XCTAssertNotNil(feed(twoSegments.reports[1]))
        XCTAssertNil(feed(twoSegments.reports[0]))
        XCTAssertNil(feed(Array(twoSegments.reports[1].prefix(19))))
        XCTAssertNil(feed(twoSegments.reports[1]), "the short segment ended the packet")
    }

    // MARK: - Feature reports

    func testThePadGoesQuietWithSdlsResetThenItsSensorEnableEachOneSegmentOnReportThree() {
        let messages = [SdlMessage.clearDigitalMappings, SdlMessage.loadDefaultSettings, SdlMessage.resetSettings, SdlMessage.rawImu]
        XCTAssertEqual(steamBleConfigReports(.quiet), messages.map(oneSegment))
    }

    func testItIsGivenBackWithTheWiredPadsRestoreAsSdlClosesIt() {
        let messages = [SdlMessage.defaultDigitalMappings, SdlMessage.loadDefaultSettings, SdlMessage.rightPadMouse]
        XCTAssertEqual(steamBleConfigReports(.restore), messages.map(oneSegment))
    }
}
