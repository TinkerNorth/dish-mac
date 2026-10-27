// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// The Direct reader's seams for tests: a reader that opens nothing, a clock
// and timers the test moves by hand, a host that records what the paths did
// to the slot list, and the pads' properties and reports as fixtures.

import DishCore
import Foundation
import IOKit.hid
import XCTest
@testable import DishEngine

/// Holds the wiring the paths handed it and the releases they asked for.
final class FakeHidPadReader: HidPadReading, @unchecked Sendable {
    private let wiringBox = LockedBox<HidPadWiring?>(nil)
    private let eventsBox = LockedBox<HidPadEvents?>(nil)
    private let releasedBox = LockedBox<[String]>([])

    var wiring: HidPadWiring? {
        wiringBox.get()
    }

    var events: HidPadEvents? {
        eventsBox.get()
    }

    var released: [String] {
        releasedBox.get()
    }

    func start(wiring: HidPadWiring, events: HidPadEvents) {
        wiringBox.set(wiring)
        eventsBox.set(events)
    }

    func release(slotId: String) {
        releasedBox.set(released + [slotId])
    }
}

/// Time moved by hand: one-shot work runs when the test advances past it,
/// and the repeating timers fire when the test says so.
@MainActor
final class ManualPathScheduler: InputPathScheduler {
    private struct Pending {
        let dueMs: Int
        let work: @MainActor () -> Void
    }

    private(set) var nowMs = 0
    private var pending: [Pending] = []
    private(set) var timers: [ManualPathTimer] = []

    func after(ms: Int, _ work: @escaping @MainActor () -> Void) {
        pending.append(Pending(dueMs: nowMs + ms, work: work))
    }

    func every(ms: Int, _ work: @escaping @MainActor () -> Void) -> InputPathTimer {
        let timer = ManualPathTimer(work: work)
        timers.append(timer)
        return timer
    }

    /// Runs, in order, the work that falls due, including work scheduled by
    /// work that ran.
    func advance(ms: Int) {
        let target = nowMs + ms
        while let next = pending.enumerated().filter({ $0.element.dueMs <= target }).min(by: { $0.element.dueMs < $1.element.dueMs }) {
            pending.remove(at: next.offset)
            nowMs = next.element.dueMs
            next.element.work()
        }
        nowMs = target
    }

    var liveTimers: [ManualPathTimer] {
        timers.filter { !$0.cancelled }
    }
}

@MainActor
final class ManualPathTimer: InputPathTimer {
    private let work: @MainActor () -> Void
    private(set) var cancelled = false

    init(work: @escaping @MainActor () -> Void) {
        self.work = work
    }

    func fire() {
        guard !cancelled else { return }
        work()
    }

    func cancel() {
        cancelled = true
    }
}

/// The paths' clock, set by the test.
@MainActor
final class PathClock {
    var nowMs: Int64 = 1_000_000

    func read() -> Int64 {
        nowMs
    }
}

/// Records what the paths asked of the slot list and the return paths.
@MainActor
final class FakePathHost: InputPathHost {
    private(set) var directSlots: [String: GameControllerInput.Slot] = [:]
    private(set) var carriersShown: [String: Bool] = [:]
    /// Every show and hide of each carrier's slot, in order.
    private(set) var carrierShowings: [String: [Bool]] = [:]
    private(set) var outputCarriers: [String: String] = [:]
    private(set) var batteries: [String: PadBattery] = [:]

    func showDirectSlot(_ slot: GameControllerInput.Slot, lane: HidPadLane) {
        directSlots[slot.id] = slot
    }

    func hideDirectSlot(_ slotId: String) {
        directSlots.removeValue(forKey: slotId)
    }

    func showCarrierSlot(_ gameControllerId: String, _ shown: Bool) {
        carriersShown[gameControllerId] = shown
        carrierShowings[gameControllerId, default: []].append(shown)
    }

    func carryOutput(directSlotId: String, via gameControllerId: String?) {
        outputCarriers[directSlotId] = gameControllerId
    }

    func directBatteryChanged(_ slotId: String, _ battery: PadBattery) {
        batteries[slotId] = battery
    }
}

/// GameController's answers, one per check, the last repeated.
@MainActor
final class ScriptedSupport {
    private var answers: [Bool]
    private(set) var asked = 0

    init(_ answers: [Bool]) {
        self.answers = answers
    }

    func answer() -> Bool {
        asked += 1
        guard answers.count > 1 else { return answers.first ?? false }
        return answers.removeFirst()
    }
}

enum DirectFixtures {
    static let n64Idle: [UInt8] = [0x30, 0x6B, 0x91, 0x00, 0x80, 0x00, 0x01, 0xC8, 0x7E, 0x00, 0x00, 0x00, 0x08, 0x00]

    /// The idle report with A held: bit 0x08 of byte 3.
    static var n64PressedA: [UInt8] {
        var bytes = n64Idle
        bytes[3] |= 0x08
        return bytes
    }

    /// X/Y/Z/Rz bytes 0-3, a 4-bit hat and 4-bit pad, 10 buttons and 6-bit
    /// pad: the desktops' plain gamepad descriptor, no report id.
    static let gamepadDescriptor: [UInt8] = [
        0x05, 0x01, 0x09, 0x05, 0xA1, 0x01, 0x05, 0x01, 0x09, 0x30, 0x09, 0x31, 0x09, 0x32, 0x09, 0x35,
        0x15, 0x00, 0x26, 0xFF, 0x00, 0x75, 0x08, 0x95, 0x04, 0x81, 0x02, 0x09, 0x39, 0x15, 0x00, 0x25,
        0x07, 0x75, 0x04, 0x95, 0x01, 0x81, 0x42, 0x75, 0x04, 0x95, 0x01, 0x81, 0x01, 0x05, 0x09, 0x19,
        0x01, 0x29, 0x0A, 0x15, 0x00, 0x25, 0x01, 0x75, 0x01, 0x95, 0x0A, 0x81, 0x02, 0x75, 0x01, 0x95,
        0x06, 0x81, 0x01, 0xC0
    ]

    static func nintendoProperties(productId: Int, transport: String = kIOHIDTransportUSBValue) -> [String: Any] {
        [
            kIOHIDVendorIDKey: 0x057E, kIOHIDProductIDKey: productId, kIOHIDProductKey: "Nintendo pad",
            kIOHIDTransportKey: transport, kIOHIDMaxInputReportSizeKey: 64
        ]
    }

    static func gamepadProperties(
        vendorId: Int = 0x1234,
        productId: Int = 0x5678,
        descriptor: [UInt8] = gamepadDescriptor
    ) -> [String: Any] {
        [
            kIOHIDVendorIDKey: vendorId, kIOHIDProductIDKey: productId, kIOHIDProductKey: "Generic Pad",
            kIOHIDTransportKey: kIOHIDTransportUSBValue, kIOHIDPrimaryUsagePageKey: 0x01, kIOHIDPrimaryUsageKey: 0x05,
            kIOHIDReportDescriptorKey: Data(descriptor), kIOHIDMaxInputReportSizeKey: 8
        ]
    }

    static func candidate(_ properties: [String: Any]) throws -> HidPadCandidate {
        try XCTUnwrap(hidPadCandidate(properties))
    }

    static func lane(_ candidate: HidPadCandidate, slotId: String, wiring: HidPadWiring) -> HidPadLane {
        HidPadLane(slotId: slotId, candidate: candidate, wiring: wiring, openedNs: 0)
    }
}

/// Feeds one report through IOKit's own callback, as the reader's run loop would.
func feedReport(_ bytes: [UInt8], to lane: HidPadLane) {
    let count = min(bytes.count, lane.capacity)
    for index in 0 ..< count {
        lane.buffer[index] = bytes[index]
    }
    let context = Unmanaged.passUnretained(lane).toOpaque()
    hidPadReportCallback(
        context: context,
        result: kIOReturnSuccess,
        sender: nil,
        type: kIOHIDReportTypeInput,
        reportId: 0,
        report: lane.buffer,
        length: count
    )
}

/// Spins the main run loop until `predicate` holds or two seconds pass.
@MainActor
func spinMainUntil(_ predicate: () -> Bool) {
    let deadline = Date().addingTimeInterval(2)
    while Date() < deadline, !predicate() {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
}

/// Runs everything already queued on the main queue: a post made before
/// this call lands before it returns.
@MainActor
func drainMain() {
    let drained = XCTestExpectation(description: "the main queue ran what was queued before")
    DispatchQueue.main.async { drained.fulfill() }
    XCTWaiter().wait(for: [drained], timeout: 2)
}
