// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// The XUSB reader's seams for tests: a bus the test plugs interfaces into
// and pulls them out of, a port that opens or refuses, and pipes that
// complete reads and record writes the way IOUSBHost does, on the reader's
// queue.

import DishCore
import Foundation
import IOKit
@testable import DishEngine

enum XusbFixtures {
    /// Type 0x00, length 0x14, nothing held, the sticks at rest.
    static let idle: [UInt8] = [0x00, 0x14] + [UInt8](repeating: 0, count: 18)

    /// The idle report with A held: bit 0x10 of byte 3.
    static var pressedA: [UInt8] {
        var bytes = idle
        bytes[3] = 0x10
        return bytes
    }

    /// The idle report with the right stick pushed to `x`.
    static func report(rightStickX x: Int16) -> [UInt8] {
        let word = UInt16(bitPattern: x)
        var bytes = idle
        bytes[10] = UInt8(truncatingIfNeeded: word)
        bytes[11] = UInt8(truncatingIfNeeded: word >> 8)
        return bytes
    }

    /// One interface of the Ultimate 2 in X-input mode, as the IORegistry
    /// gives its identity and triple: protocol 0x01 is the pad's input.
    static func ultimate2(interfaceProtocol: Int = 0x01, productId: Int = 0x310B) -> [String: Any] {
        [
            UsbInterfaceKey.vendorId: 0x2DC8, UsbInterfaceKey.productId: productId, UsbInterfaceKey.interfaceClass: 0xFF,
            UsbInterfaceKey.interfaceSubclass: 0x5D, UsbInterfaceKey.interfaceProtocol: interfaceProtocol
        ]
    }
}

/// An interrupt IN pipe the test feeds: a report completes the read in
/// flight on the reader's queue, as IOUSBHost completes it. Its state is the
/// reader queue's alone, so a run in the reader's role takes no lock.
final class FakeUsbInputPipe: UsbInputPipe, @unchecked Sendable {
    static let capacity = 32

    private let queue: DispatchQueue
    private let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: FakeUsbInputPipe.capacity)

    /// Every read is refused, as a pipe that will not take one refuses it.
    private let refusing: Bool

    // Touched only on the queue.
    private var pending: UsbReadCompletion?
    private var readsAsked = 0

    init(queue: DispatchQueue, refusingReads: Bool = false) {
        self.queue = queue
        refusing = refusingReads
        buffer.initialize(repeating: 0, count: Self.capacity)
    }

    deinit {
        buffer.deallocate()
    }

    /// Every read the reader asked for so far.
    var reads: Int {
        queue.sync { readsAsked }
    }

    func received(_ length: Int) -> UnsafeBufferPointer<UInt8> {
        UnsafeBufferPointer(start: buffer, count: min(length, Self.capacity))
    }

    func read(_ completion: @escaping UsbReadCompletion) -> IOReturn {
        readsAsked += 1
        guard !refusing else { return kIOReturnNotResponding }
        pending = completion
        return kIOReturnSuccess
    }

    /// One report off the wire; with no read in flight it is lost.
    func deliver(_ report: [UInt8]) {
        queue.sync { complete(report) }
    }

    /// The same, from a producer that does not wait for the reader.
    func post(_ report: [UInt8]) {
        queue.async { self.complete(report) }
    }

    /// The read in flight fails.
    func fail(_ status: IOReturn) {
        queue.sync { takePending()?(status, 0) }
    }

    /// The read in flight completes as aborted, after the caller returns.
    func abortPending() {
        queue.async { self.takePending()?(kIOReturnAborted, 0) }
    }

    private func complete(_ report: [UInt8]) {
        guard let completion = takePending() else { return }
        let count = min(report.count, Self.capacity)
        for index in 0 ..< count {
            buffer[index] = report[index]
        }
        completion(kIOReturnSuccess, count)
    }

    private func takePending() -> UsbReadCompletion? {
        defer { pending = nil }
        return pending
    }
}

/// An interrupt OUT pipe that keeps every report it was handed, in order.
/// Once wedged, as a pad that stays attached but takes no transfer, a write
/// blocks until the pipe is aborted and then fails as aborted.
final class FakeUsbOutputPipe: UsbOutputPipe, @unchecked Sendable {
    private let writesBox = LockedBox<[[UInt8]]>([])
    private let wedgedBox = LockedBox(false)
    private let abortsBox = LockedBox(0)
    private let aborted = DispatchSemaphore(value: 0)

    var writes: [[UInt8]] {
        writesBox.get()
    }

    var aborts: Int {
        abortsBox.get()
    }

    func wedge() {
        wedgedBox.set(true)
    }

    func write(_ bytes: [UInt8]) -> IOReturn {
        guard !wedgedBox.get() else { return blockUntilAborted() }
        writesBox.mutate { $0.append(bytes) }
        return kIOReturnSuccess
    }

    func abort() {
        abortsBox.mutate { $0 += 1 }
        aborted.signal()
    }

    private func blockUntilAborted() -> IOReturn {
        aborted.wait()
        return kIOReturnAborted
    }
}

final class FakeXusbInterface: XusbOpenInterface, @unchecked Sendable {
    let fakeInput: FakeUsbInputPipe
    let fakeOutput = FakeUsbOutputPipe()
    private let closedBox = LockedBox(false)

    init(queue: DispatchQueue, refusingReads: Bool) {
        fakeInput = FakeUsbInputPipe(queue: queue, refusingReads: refusingReads)
    }

    var input: UsbInputPipe {
        fakeInput
    }

    var output: UsbOutputPipe? {
        fakeOutput
    }

    var closed: Bool {
        closedBox.get()
    }

    /// As IOUSBHost's asynchronous abort: the read in flight completes later.
    func close() {
        closedBox.set(true)
        fakeInput.abortPending()
    }
}

/// Opens one fake interface on the queue it is handed, or refuses as a
/// device another client holds refuses.
final class FakeXusbPort: XusbPort, @unchecked Sendable {
    private let refusal: IOReturn?
    private let refusingReads: Bool
    private let interfaceBox = LockedBox<FakeXusbInterface?>(nil)
    private let opensBox = LockedBox(0)

    init(refusing refusal: IOReturn? = nil, refusingReads: Bool = false) {
        self.refusal = refusal
        self.refusingReads = refusingReads
    }

    var interface: FakeXusbInterface? {
        interfaceBox.get()
    }

    var opens: Int {
        opensBox.get()
    }

    func open(queue: DispatchQueue) throws -> XusbOpenInterface {
        opensBox.mutate { $0 += 1 }
        if let refusal { throw NSError(domain: "IOUSBHostErrorDomain", code: Int(refusal)) }
        let opened = FakeXusbInterface(queue: queue, refusingReads: refusingReads)
        interfaceBox.set(opened)
        return opened
    }
}

/// A bus the test plugs interfaces into and pulls them out of, each event
/// delivered on the reader's queue before the call returns.
final class FakeXusbBus: XusbBus, @unchecked Sendable {
    private let startBox = LockedBox<(queue: DispatchQueue, events: XusbBusEvents)?>(nil)

    func start(queue: DispatchQueue, events: XusbBusEvents) {
        startBox.set((queue, events))
    }

    var started: Bool {
        startBox.get() != nil
    }

    func plug(_ registryId: UInt64, _ properties: [String: Any], port: XusbPort) {
        guard let start = startBox.get() else { return }
        start.queue.sync { start.events.arrived(XusbInterfaceArrival(registryId: registryId, properties: properties, port: port)) }
    }

    func unplug(_ registryId: UInt64) {
        guard let start = startBox.get() else { return }
        start.queue.sync { start.events.removed(registryId) }
    }
}
