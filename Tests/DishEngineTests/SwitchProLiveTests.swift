// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import GameController
import IOKit.hid
import XCTest
@testable import DishEngine

/// The Direct reader against a real Switch Pro Controller on USB, which
/// macOS's driver leaves silent: the reader's own start sequence has to
/// bring its full reports, and its motion. It runs only with the pad
/// attached and `DISH_LIVE_SWITCH_PRO=1`, from the pad's plugged-in state,
/// and hands the pad back in it.
final class SwitchProLiveTests: XCTestCase {
    private static let slotId = "hid:057e:2009"
    private static let streamDeadline: TimeInterval = 8
    /// A streaming Pro sends about 75 full reports a second on USB.
    private static let leastReportsPerSecond: UInt64 = 50
    private static let motionDeadline: TimeInterval = 4
    /// At rest the accelerometer reads gravity, whichever way the pad lies.
    private static let restingG = 0.8 ... 1.2

    private static var enabled: Bool {
        ProcessInfo.processInfo.environment["DISH_LIVE_SWITCH_PRO"] == "1"
    }

    private let reader = IOKitHidPadReader()
    private let processor = GamepadInputProcessor()
    private let arrivals = ArrivalLog()

    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(Self.enabled, "runs only with a Switch Pro Controller on USB and DISH_LIVE_SWITCH_PRO=1")
        try SwitchProUsbLink.restorePluggedInState()
    }

    /// A skipped run never touches the pad.
    override func tearDownWithError() throws {
        if Self.enabled { try handBack() }
        try super.tearDownWithError()
    }

    private func handBack() throws {
        reader.release(slotId: Self.slotId)
        try SwitchProUsbLink.restorePluggedInState()
    }

    func testTheReaderBringsAQuietProToStreamItsFullReports() throws {
        let lane = try streamingLane()
        XCTAssertGreaterThanOrEqual(reportsInOneSecond(lane), Self.leastReportsPerSecond, "the stream keeps coming")
    }

    /// The Pro's IMU is off until subcommand 0x40 turns it on: every IMU
    /// word of its full reports reads zero, however the pad lies.
    func testAProAtRestReadsGravityOnItsAccelerometerOnceItStreams() throws {
        _ = try streamingLane()
        let readsGravity = waitUntil(Self.motionDeadline) { latestAccelG().map(Self.restingG.contains) ?? false }
        let samples = processor.tallySnapshot().motion[Self.slotId] ?? 0
        let last = String(describing: processor.latestInput(Self.slotId)?.motion)
        XCTAssertTrue(readsGravity, "about 1 g within \(Self.motionDeadline) s; the last of \(samples) motion samples read \(last)")
    }

    /// The reader opens the Pro, the lane is routed Direct, and its first
    /// full report has arrived.
    private func streamingLane() throws -> HidPadLane {
        reader.start(wiring: LiveWiring.into(processor), events: HidPadEvents(arrived: arrivals.recorder(), removed: ignoreRemoval))
        let lane = try XCTUnwrap(waitForLane(), "the reader opened the Pro")
        lane.gate.route(.direct)
        let streamed = waitUntil(Self.streamDeadline) { lane.latestBattery != nil }
        let reports = lane.tally.snapshot().reports
        XCTAssertTrue(streamed, "a full report within \(Self.streamDeadline) s; the pad sent \(reports) reports in all")
        return lane
    }

    /// The last motion sample's acceleration in g, off the wire's ±4 g scale.
    private func latestAccelG() -> Double? {
        guard let motion = processor.latestInput(Self.slotId)?.motion else { return nil }
        let x = Double(motion.accelX)
        let y = Double(motion.accelY)
        let z = Double(motion.accelZ)
        return (x * x + y * y + z * z).squareRoot() / Double(scaleAccel(1))
    }

    private func reportsInOneSecond(_ lane: HidPadLane) -> UInt64 {
        let before = lane.tally.snapshot().reports
        Thread.sleep(forTimeInterval: 1)
        return lane.tally.snapshot().reports - before
    }

    private func waitForLane() -> HidPadLane? {
        let arrived = waitUntil(2) { arrivals.lane(Self.slotId) != nil }
        return arrived ? arrivals.lane(Self.slotId) : nil
    }

    private func waitUntil(_ seconds: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        return condition()
    }
}

/// The lanes the reader announced, from its own thread.
private final class ArrivalLog: Sendable {
    private let arrivals = LockedBox<[HidPadArrival]>([])

    func recorder() -> @Sendable (HidPadArrival) -> Void {
        { [arrivals] arrival in arrivals.mutate { $0.append(arrival) } }
    }

    func lane(_ slotId: String) -> HidPadLane? {
        arrivals.get().first { $0.slotId == slotId }?.lane
    }
}

@Sendable
private func ignoreRemoval(_: String) {}

/// A lane's wiring that publishes into the test's processor, whose records
/// the test reads; nothing else listens.
private enum LiveWiring {
    static func into(_ processor: GamepadInputProcessor) -> HidPadWiring {
        HidPadWiring(processor: processor, notify: ignoreNotify, battery: ignoreBattery)
    }
}

@Sendable
private func ignoreNotify(_: String, _: InputSource) {}

@Sendable
private func ignoreBattery(_: String, _: PadBattery) {}

/// The Pro as plugged in: 0x80 0x05 lets it time out again, which ends any
/// stream an earlier run started, and it then stays silent until a start
/// sequence.
private enum SwitchProUsbLink {
    private static let allowTimeout: [UInt8] = [0x80, 0x05]
    private static let settleSeconds: TimeInterval = 0.5

    static func restorePluggedInState() throws {
        let device = try XCTUnwrap(attachedPro(), "no Switch Pro Controller on USB")
        XCTAssertEqual(IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone)), kIOReturnSuccess)
        var packet = allowTimeout + [UInt8](repeating: 0, count: switchStartPacketBytes - allowTimeout.count)
        let status = IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, CFIndex(allowTimeout[0]), &packet, packet.count)
        XCTAssertEqual(status, kIOReturnSuccess)
        XCTAssertEqual(IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone)), kIOReturnSuccess)
        Thread.sleep(forTimeInterval: settleSeconds)
    }

    private static func attachedPro() -> IOHIDDevice? {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching: [String: Any] = [
            kIOHIDVendorIDKey: Int(DirectVendor.nintendo), kIOHIDProductIDKey: 0x2009, kIOHIDTransportKey: kIOHIDTransportUSBValue,
            kIOHIDGCSyntheticDeviceKey: false
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
        let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> ?? []
        return devices.first
    }
}
