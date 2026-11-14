// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import XCTest
@testable import DishEngine

/// A Steam Controller's lane on the reader's thread: its state reaches the
/// processor like any Direct pad's, a receiver's slot holds a pad only once
/// its controller shows a sign of life, a controller that leaves releases
/// what it held, and every arrival is handed to the output to configure.
final class SteamLaneTests: XCTestCase {

    private let reports = LockedBox<[GamepadReport]>([])
    private let motion = LockedBox<[MotionSample]>([])
    private let touches = LockedBox<[TouchpadSample]>([])
    private let wheel = LockedBox<[Int16]>([])
    private let batteries = LockedBox<[PadBattery]>([])
    private let links = LockedBox<[String]>([])
    private let output = FakeDirectOutput()
    private let processor = GamepadInputProcessor()

    private func lane(productId: Int, interfaceNumber: Int?) throws -> HidPadLane {
        let reports = reports
        let motion = motion
        let touches = touches
        let wheel = wheel
        let batteries = batteries
        let links = links
        processor.send(
            reports: { _, report in reports.mutate { $0.append(report) } },
            motion: { _, sample, _ in motion.mutate { $0.append(sample) } },
            touchpad: { _, sample, _, scrollV in
                touches.mutate { $0.append(sample) }
                wheel.mutate { $0.append(scrollV) }
            }
        )
        var wiring = HidPadWiring(
            processor: processor,
            notify: { _, _ in },
            battery: { _, battery in batteries.mutate { $0.append(battery) } }
        )
        wiring.linkChanged = { slotId in links.mutate { $0.append(slotId) } }
        let properties = DirectFixtures.valveProperties(productId: productId, interfaceNumber: interfaceNumber)
        let candidate = try DirectFixtures.candidate(properties)
        return DirectFixtures.lane(candidate, slotId: "hid:28de:\(String(format: "%04x", productId))", wiring: wiring, output: output)
    }

    private func steamState(_ buttons: UInt32) -> [UInt8] {
        SteamLanePackets.state(buttons)
    }

    private static let leftPadClicked: UInt32 = 0x020000
    private static let rightPadClicked: UInt32 = 0x040000
    private static let leftPadFinger: UInt32 = 0x080000
    private static let rightPadFinger: UInt32 = 0x100000

    /// A state packet with the left pad's y (the shared left axes, bytes
    /// 18...19) and the right pad's x (bytes 20...21).
    private func padState(_ buttons: UInt32, leftY: Int16 = 0, rightX: Int16 = 0) -> [UInt8] {
        var bytes = steamState(buttons)
        bytes[18] = UInt8(truncatingIfNeeded: UInt16(bitPattern: leftY))
        bytes[19] = UInt8(truncatingIfNeeded: UInt16(bitPattern: leftY) >> 8)
        bytes[20] = UInt8(truncatingIfNeeded: UInt16(bitPattern: rightX))
        bytes[21] = UInt8(truncatingIfNeeded: UInt16(bitPattern: rightX) >> 8)
        return bytes
    }

    // MARK: - The trackpads by the slot's pick

    func testThe2015RightPadIsTheRightStickUntilThePickSaysPad() throws {
        let pad = try lane(productId: 0x1102, interfaceNumber: 2)
        pad.gate.route(.direct)
        feedReport(padState(Self.rightPadFinger, rightX: 10000), to: pad)
        XCTAssertEqual(reports.get().last?.rx, 9659, "the stick pick is the lane's default")
        XCTAssertEqual(touches.get(), [], "the stick puts nothing on the surface")
        pad.useTrackpadPick(.pad)
        feedReport(padState(Self.rightPadFinger, rightX: 10001), to: pad)
        XCTAssertEqual(reports.get().last?.rx, 0, "the pad pick gives up the stick")
        let touch = try XCTUnwrap(touches.get().last)
        XCTAssertTrue(touch.finger1.active, "the right pad is finger 1")
        XCTAssertGreaterThan(touch.finger1.x, 16384, "on the right half")
        XCTAssertFalse(touch.finger0.active)
    }

    func testMouseModeLandsTheLeftPadClickOnTheRightButtonAndItsTravelOnTheWheel() throws {
        let pad = try lane(productId: 0x1102, interfaceNumber: 2)
        pad.gate.route(.direct)
        pad.useTrackpadPick(.mouse)
        feedReport(padState(Self.leftPadFinger | Self.leftPadClicked), to: pad)
        let clicked = try XCTUnwrap(touches.get().last)
        XCTAssertTrue(clicked.rightButtonPressed)
        XCTAssertFalse(clicked.buttonPressed)
        XCTAssertFalse(clicked.finger0.active, "the left pad is no finger in mouse mode")
        XCTAssertEqual(reports.get().last?.buttons, 0, "neither L3 nor R3")
        feedReport(padState(Self.leftPadFinger | Self.leftPadClicked, leftY: 5000), to: pad)
        XCTAssertEqual(wheel.get().last, ProtocolConstants.scrollUnitsPerNotch, "one notch of travel")
    }

    func testOffPutsThePadClicksOnTheWordAndLiftsTheSurface() throws {
        let pad = try lane(productId: 0x1102, interfaceNumber: 2)
        pad.gate.route(.direct)
        pad.useTrackpadPick(.pad)
        feedReport(padState(Self.rightPadFinger, rightX: 10000), to: pad)
        XCTAssertEqual(touches.get().last?.finger1.active, true)
        pad.useTrackpadPick(.off)
        feedReport(padState(Self.rightPadFinger | Self.rightPadClicked, rightX: 10000), to: pad)
        XCTAssertEqual(reports.get().last?.extButtons, ProtocolConstants.extButtonRightPadClick)
        XCTAssertEqual(reports.get().last?.buttons, 0, "not R3")
        XCTAssertEqual(touches.get().last?.finger1.active, false, "the surface lifts once")
    }

    func testTheSurfaceIsPublishedOnChangeOnly() throws {
        let pad = try lane(productId: 0x1102, interfaceNumber: 2)
        pad.gate.route(.direct)
        pad.useTrackpadPick(.pad)
        feedReport(padState(Self.rightPadFinger, rightX: 10000), to: pad)
        feedReport(padState(Self.rightPadFinger, rightX: 10000), to: pad)
        XCTAssertEqual(touches.get().count, 1, "a repeat of the surface is not sent")
        feedReport(padState(Self.rightPadFinger, rightX: 12000), to: pad)
        XCTAssertEqual(touches.get().count, 2)
    }

    // MARK: - A wired pad

    func testAWired2015PadIsThereFromTheStartAndPublishesItsState() throws {
        let pad = try lane(productId: 0x1102, interfaceNumber: 2)
        XCTAssertTrue(pad.linked)
        XCTAssertFalse(pad.startsWithSwitchSequence)
        pad.gate.route(.direct)
        feedReport(steamState(0), to: pad)
        feedReport(steamState(0x80), to: pad)
        XCTAssertEqual(reports.get(), [.released, GamepadReport(buttons: WireButton.faceA.bit)])
        XCTAssertEqual(output.calls, [], "a wired pad's state is no arrival")
        XCTAssertEqual(links.get(), [])
    }

    func testThe2015PadsImuReachesTheMotionStream() throws {
        let pad = try lane(productId: 0x1102, interfaceNumber: 2)
        pad.gate.route(.direct)
        var packet = steamState(0)
        packet[28] = 0x10
        feedReport(packet, to: pad)
        XCTAssertEqual(motion.get().count, 1)
    }

    func testA2015PadOverBluetoothIsThereFromTheStartAndPublishesEachAssembledState() throws {
        let pad = try lane(productId: 0x1106, interfaceNumber: nil)
        XCTAssertTrue(pad.linked, "it is there while macOS lists it")
        pad.gate.route(.direct)
        feedReport(SteamLanePackets.bleState(0), to: pad)
        feedReport(SteamLanePackets.bleState(0x80), to: pad)
        XCTAssertEqual(reports.get(), [.released, GamepadReport(buttons: WireButton.faceA.bit)])
        XCTAssertEqual(output.calls, [], "a state is no arrival")
    }

    // MARK: - A receiver's slot

    func testAReceiversSlotHoldsNoPadUntilItsControllerShowsUp() throws {
        let slot = try lane(productId: 0x1142, interfaceNumber: 1)
        XCTAssertFalse(slot.linked)
        feedReport(SteamLanePackets.wireless(0x02), to: slot)
        XCTAssertTrue(slot.linked)
        XCTAssertEqual(output.calls, [.connected])
        XCTAssertEqual(links.get(), ["hid:28de:1142"])
    }

    func testAStateReportIsASignOfLifeWhenTheConnectEventWasMissed() throws {
        let slot = try lane(productId: 0x1142, interfaceNumber: 1)
        feedReport(steamState(0), to: slot)
        feedReport(steamState(0), to: slot)
        XCTAssertTrue(slot.linked)
        XCTAssertEqual(output.calls, [.connected], "configured once")
        XCTAssertEqual(links.get().count, 1)
    }

    func testAConnectEventWhileLinkedConfiguresAgainWithoutTellingTheSlotList() throws {
        let slot = try lane(productId: 0x1142, interfaceNumber: 1)
        feedReport(SteamLanePackets.wireless(0x02), to: slot)
        feedReport(SteamLanePackets.wireless(0x02), to: slot)
        XCTAssertEqual(output.calls, [.connected, .connected], "a returning pad has rebooted, its settings gone")
        XCTAssertEqual(links.get().count, 1)
    }

    func testAControllerThatLeavesReleasesWhatItHeld() throws {
        let slot = try lane(productId: 0x1142, interfaceNumber: 1)
        slot.gate.route(.direct)
        feedReport(steamState(0), to: slot)
        feedReport(steamState(0x80), to: slot)
        feedReport(SteamLanePackets.wireless(0x01), to: slot)
        XCTAssertFalse(slot.linked)
        XCTAssertEqual(reports.get().last, .released, "no button stays held on the host")
        XCTAssertEqual(output.calls, [.connected, .left])
        XCTAssertEqual(links.get().count, 2)
        feedReport(SteamLanePackets.wireless(0x01), to: slot)
        XCTAssertEqual(output.calls, [.connected, .left], "a second disconnect changes nothing")
    }

    // MARK: - The 2026 pad

    func testA2026PadsBatteryIsPostedWhileItIsForwarded() throws {
        let pad = try lane(productId: 0x1302, interfaceNumber: nil)
        let battery: [UInt8] = [0x43, 0x02, 0x41] + [UInt8](repeating: 0, count: 12)
        feedReport(battery, to: pad)
        XCTAssertEqual(batteries.get(), [], "not forwarded, nothing posted")
        pad.gate.route(.direct)
        feedReport(battery, to: pad)
        feedReport(battery, to: pad)
        XCTAssertEqual(batteries.get(), [PadBattery(level: 65, status: .charging)], "once per change")
        XCTAssertEqual(pad.latestBattery, PadBattery(level: 65, status: .charging))
    }

    func testA2026PadsStateReachesTheProcessor() throws {
        let pad = try lane(productId: 0x1302, interfaceNumber: nil)
        pad.gate.route(.direct)
        var report = [UInt8](repeating: 0, count: 46)
        report[0] = 0x42
        feedReport(report, to: pad)
        report[2] = 0x02
        feedReport(report, to: pad)
        XCTAssertEqual(reports.get(), [.released, GamepadReport(buttons: WireButton.faceB.bit)])
    }

    func testA2026PadOverBluetoothPublishesItsBluetoothStateReport() throws {
        let pad = try lane(productId: 0x1303, interfaceNumber: nil)
        pad.gate.route(.direct)
        var report = [UInt8](repeating: 0, count: 46)
        report[0] = 0x45
        feedReport(report, to: pad)
        report[2] = 0x01
        feedReport(report, to: pad)
        XCTAssertEqual(reports.get(), [.released, GamepadReport(buttons: WireButton.faceA.bit)])
    }
}

/// The 2015 pad's packets as the lane hears them: a state packet with its
/// 24-bit button word, and the receiver's wireless event (payload 0x01
/// disconnected, 0x02 connected).
private enum SteamLanePackets {
    static func state(_ buttons: UInt32) -> [UInt8] {
        var bytes = framed(type: 0x01, length: 44)
        bytes[8] = UInt8(buttons & 0xFF)
        bytes[9] = UInt8((buttons >> 8) & 0xFF)
        bytes[10] = UInt8((buttons >> 16) & 0xFF)
        return bytes
    }

    /// Over Bluetooth LE, one segment of report 3 (the packet's first and
    /// last) carrying a state packet that names only its button chunk.
    static func bleState(_ buttons: UInt32) -> [UInt8] {
        let packet: [UInt8] = [0x14, 0x00, UInt8(buttons & 0xFF), UInt8((buttons >> 8) & 0xFF), UInt8((buttons >> 16) & 0xFF)]
        return [0x03, 0xC0] + packet + [UInt8](repeating: 0, count: 18 - packet.count)
    }

    static func wireless(_ payload: UInt8) -> [UInt8] {
        var bytes = framed(type: 0x03, length: 0x01)
        bytes[4] = payload
        return bytes
    }

    private static func framed(type: UInt8, length: UInt8) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 64)
        bytes[0] = 0x01
        bytes[2] = type
        bytes[3] = length
        return bytes
    }
}
