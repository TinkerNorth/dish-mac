// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import Foundation
import XCTest
@testable import DishEngine

/// The XUSB reader's IOUSBHost bus against this Mac's own USB tree: it
/// hands over every interface already there with the identity and triple
/// the reader decides on. With an 8BitDo Ultimate 2 attached in X-input
/// mode and `DISH_LIVE_XUSB=1`, the reader configures the pad when nothing
/// has, opens its XUSB interface and decodes its reports.
final class XusbLiveTests: XCTestCase {
    private static let slotId = "hid:2dc8:310b"
    private static let reportDeadline: TimeInterval = 4

    private static var padAttached: Bool {
        ProcessInfo.processInfo.environment["DISH_LIVE_XUSB"] == "1"
    }

    func testTheBusHandsOverTheInterfacesAlreadyThereWithWhatTheReaderDecidesOn() throws {
        let queue = ThreadRole.hidReader.queue(label: XusbPadReader.queueLabel, qos: .userInteractive)
        let found = LockedBox<[XusbInterfaceArrival]>([])
        let events = XusbBusEvents(arrived: { arrival in found.mutate { $0.append(arrival) } }, removed: ignoreInterfaceRemoval)
        queue.sync { IOUSBHostXusbBus().start(queue: queue, events: events) }
        let arrivals = found.get()
        try XCTSkipIf(arrivals.isEmpty, "this machine lists no USB interface")
        let keys: Set = [
            UsbInterfaceKey.vendorId, UsbInterfaceKey.productId, UsbInterfaceKey.interfaceClass,
            UsbInterfaceKey.interfaceSubclass, UsbInterfaceKey.interfaceProtocol
        ]
        for arrival in arrivals {
            XCTAssertEqual(Set(arrival.properties.keys), keys, "registry entry \(arrival.registryId)")
            XCTAssertNotEqual(arrival.registryId, 0)
        }
    }

    func testTheReaderOpensAnAttachedUltimate2AndDecodesItsReports() throws {
        try XCTSkipUnless(Self.padAttached, "runs only with an 8BitDo Ultimate 2 in X-input mode on USB and DISH_LIVE_XUSB=1")
        let processor = GamepadInputProcessor()
        let lanes = LockedBox<[HidPadLane]>([])
        let refusals = LockedBox<[ClaimRefusal]>([])
        let events = HidPadEvents(
            arrived: { arrival in lanes.mutate { $0.append(arrival.lane) } },
            removed: ignoreSlotRemoval,
            refused: { _, refusal in refusals.mutate { $0.append(refusal) } }
        )
        let reader = XusbPadReader(bus: IOUSBHostXusbBus())
        reader.start(wiring: HidPadWiring(processor: processor, notify: ignoreGateEvent, battery: { _, _ in }), events: events)
        let opened = waitUntil(Self.reportDeadline) { !lanes.get().isEmpty }
        XCTAssertTrue(opened, "the reader opened the pad's XUSB interface")
        XCTAssertEqual(refusals.get(), [], "no other client holds it")
        let lane = try XCTUnwrap(lanes.get().first { $0.slotId == Self.slotId })
        lane.gate.route(.direct)
        let reported = waitUntil(Self.reportDeadline) { processor.latestInput(Self.slotId)?.raw != nil }
        XCTAssertTrue(reported, "an input report decoded; the pipe read \(lane.tally.snapshot().reports) reports in all")
        XCTAssertEqual(processor.latestInput(Self.slotId)?.raw?.extButtons, 0)
    }

    private func waitUntil(_ seconds: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        return condition()
    }
}

@Sendable
private func ignoreSlotRemoval(_: String) {}

private func ignoreInterfaceRemoval(_: UInt64) {}
