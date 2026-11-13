// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// The XUSB reader: Xbox 360 vendor interfaces macOS has no driver for (an
// 8BitDo Ultimate 2 in X-input mode), opened through IOUSBHost and read on
// a queue of its own, never the main one. The bus reports each interface as
// it appears and goes; the reader opens the ones its model table names,
// reads each one's interrupt IN pipe a report at a time into a Direct lane,
// as the HID reader's callback feeds its lanes, and hands the lane's output
// the interrupt OUT pipe for rumble. An interface another client holds is
// refused, and the paths hear it as a refused claim.

import DishCore
import Foundation
import IOKit
import os

/// A read's status and its length, on the reader's queue.
typealias UsbReadCompletion = @Sendable (IOReturn, Int) -> Void

/// An interface's interrupt IN pipe: one read in flight, into a buffer the
/// pipe owns for its whole life.
protocol UsbInputPipe: AnyObject {
    /// What the last read wrote, from the start of the buffer.
    func received(_ length: Int) -> UnsafeBufferPointer<UInt8>
    /// Asks for the next report; anything but success means none will come.
    func read(_ completion: @escaping UsbReadCompletion) -> IOReturn
}

/// An interface's interrupt OUT pipe; a write returns once the transfer has.
protocol UsbOutputPipe: AnyObject, Sendable {
    func write(_ bytes: [UInt8]) -> IOReturn
    /// Fails the write in flight as aborted, without waiting for it.
    func abort()
}

/// An interface the reader opened, until it is closed.
protocol XusbOpenInterface: AnyObject {
    var input: UsbInputPipe { get }
    /// Nil for an interface with nowhere to send rumble.
    var output: UsbOutputPipe? { get }
    /// Stops the reads and gives the interface back.
    func close()
}

/// Opens one interface for the reader.
protocol XusbPort: AnyObject {
    /// Opens it for Dish alone, its IO serviced on `queue`; throws when
    /// another client holds it or it would not open.
    func open(queue: DispatchQueue) throws -> XusbOpenInterface
}

/// One interface as the bus found it, before the reader decides on it.
struct XusbInterfaceArrival {
    let registryId: UInt64
    /// The interface's IORegistry properties: its device's USB identity and
    /// its own class, subclass and protocol.
    let properties: [String: Any]
    let port: XusbPort
}

/// What the bus tells the reader, on the reader's queue.
struct XusbBusEvents {
    let arrived: (XusbInterfaceArrival) -> Void
    let removed: (_ registryId: UInt64) -> Void
}

/// The USB side the reader stands on: IOUSBHost in the app, a fake in tests.
protocol XusbBus: AnyObject {
    /// Starts watching, on `queue`; an interface already there arrives at once.
    func start(queue: DispatchQueue, events: XusbBusEvents)
}

/// The IORegistry keys an interface's identity and triple are read under.
enum UsbInterfaceKey {
    static let vendorId = "idVendor"
    static let productId = "idProduct"
    static let interfaceClass = "bInterfaceClass"
    static let interfaceSubclass = "bInterfaceSubClass"
    static let interfaceProtocol = "bInterfaceProtocol"
}

/// The interface the reader reads, or nil: any interface whose triple is not
/// a wired 360 pad's, and an XUSB interface of a model the table does not
/// name as one.
func xusbPadCandidate(_ properties: [String: Any]) -> HidPadCandidate? {
    let xusb = isXusbInterface(
        interfaceClass: properties[UsbInterfaceKey.interfaceClass] as? Int,
        subclass: properties[UsbInterfaceKey.interfaceSubclass] as? Int,
        interfaceProtocol: properties[UsbInterfaceKey.interfaceProtocol] as? Int
    )
    let vendorId = UInt16(clamping: properties[UsbInterfaceKey.vendorId] as? Int ?? 0)
    let productId = UInt16(clamping: properties[UsbInterfaceKey.productId] as? Int ?? 0)
    guard xusb, let model = directModel(vendorId: vendorId, productId: productId), model.decoder == .xusb else { return nil }
    return HidPadCandidate(
        vendorId: vendorId,
        productId: productId,
        product: "",
        transport: .usb,
        model: model,
        decoder: .xusb,
        reportCapacity: HidPadLimits.minimumReportCapacity
    )
}

extension GameControllerProbe {
    /// macOS has no driver for an XUSB pad, so GameController never lists one.
    static let neverListed = GameControllerProbe { false }
}

// MARK: - One pad's reads

/// One pad's reads on the reader's queue: each report decoded in place by
/// its lane, then the next read; a failed read ends them.
final class XusbReadLoop: @unchecked Sendable {
    private let lane: HidPadLane
    private let pipe: UsbInputPipe
    private let failed: (_ slotId: String, _ status: IOReturn) -> Void
    /// Made once, so a read hands the pipe nothing new.
    private lazy var completion: UsbReadCompletion = { [weak self] status, length in
        self?.completed(status, length)
    }

    init(lane: HidPadLane, pipe: UsbInputPipe, failed: @escaping (_ slotId: String, _ status: IOReturn) -> Void) {
        self.lane = lane
        self.pipe = pipe
        self.failed = failed
    }

    /// The first read; anything but success means the pad cannot be read.
    func start() -> IOReturn {
        pipe.read(completion)
    }

    private func completed(_ status: IOReturn, _ length: Int) {
        guard status == kIOReturnSuccess else { return failed(lane.slotId, status) }
        lane.receive(pipe.received(length), nowNs: DispatchTime.now().uptimeNanoseconds)
        let next = pipe.read(completion)
        if next != kIOReturnSuccess { failed(lane.slotId, next) }
    }
}

// MARK: - The reader

final class XusbPadReader: HidPadReading, @unchecked Sendable {
    static let log = Logger(subsystem: "com.tinkernorth.dish", category: "Direct")
    static let queueLabel = "com.tinkernorth.dish.xusb"

    /// One interface the reader holds: its lane, and while Dish reads it,
    /// the open interface and the reads that feed the lane.
    private struct Entry {
        let lane: HidPadLane
        let interface: XusbOpenInterface?
        let reads: XusbReadLoop?
    }

    private let bus: XusbBus
    /// Every bus event and every read completes here, so the entries stay
    /// single-threaded.
    let queue: DispatchQueue
    /// How long quitting waits for each pad's stop.
    let quitBoundMs: Int
    private let started = AtomicBool(false)

    // Touched only on the queue.
    private var entries = HidEntryRegistry<Entry>()
    private var wiring: HidPadWiring?
    private var events: HidPadEvents?

    init(
        bus: XusbBus,
        queue: DispatchQueue = ThreadRole.hidReader.queue(label: XusbPadReader.queueLabel, qos: .userInteractive),
        quitBoundMs: Int = XusbOutput.quitStopBoundMs
    ) {
        self.bus = bus
        self.queue = queue
        self.quitBoundMs = quitBoundMs
    }

    func start(wiring: HidPadWiring, events: HidPadEvents) {
        guard !started.getAndSet(true) else { return }
        queue.async { [self] in begin(wiring: wiring, events: events) }
    }

    /// GameController never lists an XUSB pad, so none is released to it.
    func release(slotId: String) {}

    /// An XUSB pad is read from its arrival, never on a claim.
    func claim(slotId: String) {}

    func unclaim(slotId: String) {}

    // MARK: - On the queue

    private func begin(wiring: HidPadWiring, events: HidPadEvents) {
        self.wiring = wiring
        self.events = events
        let busEvents = XusbBusEvents(
            arrived: { [weak self] in self?.arrived($0) },
            removed: { [weak self] in self?.removed($0) }
        )
        bus.start(queue: queue, events: busEvents)
    }

    /// An interface the model table names is opened at once; the paths hear
    /// of it either way, read or refused.
    private func arrived(_ arrival: XusbInterfaceArrival) {
        guard !entries.knows(arrival.registryId), let wiring else { return }
        guard let candidate = xusbPadCandidate(arrival.properties) else { return }
        let taken = Set(entries.reading.map(\.lane.slotId))
        let slotId = lowestFreeSlotId(base: directSlotBase(vendorId: candidate.vendorId, productId: candidate.productId), taken: taken)
        let pad = XusbArrivingPad(registryId: arrival.registryId, slotId: slotId, candidate: candidate, wiring: wiring)
        blockingRegion("xusb.open")
        switch Result(catching: { try arrival.port.open(queue: queue) }) {
        case let .success(interface): read(pad, interface)
        case let .failure(error): refuse(pad, status: ioReturn(of: error))
        }
    }

    /// The reads start before the paths hear of the pad: its lane keeps the
    /// first reports as the baseline until it is forwarded.
    private func read(_ pad: XusbArrivingPad, _ interface: XusbOpenInterface) {
        let output = interface.output.map { XusbOutput(slotId: pad.slotId, pipe: $0, quitBoundMs: quitBoundMs) }
        let lane = pad.lane(output: output)
        let reads = XusbReadLoop(lane: lane, pipe: interface.input) { [weak self] slotId, status in
            self?.readFailed(slotId, status)
        }
        let first = reads.start()
        guard first == kIOReturnSuccess else {
            interface.close()
            return refuse(pad, status: first)
        }
        entries.file(pad.registryId, Entry(lane: lane, interface: interface, reads: reads))
        events?.arrived(HidPadArrival(slotId: pad.slotId, lane: lane, probe: .neverListed))
    }

    /// The pad is filed with nothing open, so its removal ends it like any.
    private func refuse(_ pad: XusbArrivingPad, status: IOReturn) {
        Self.log.error("XUSB open refused id=\(pad.slotId, privacy: .public) status=\(status)")
        let lane = pad.lane(output: nil)
        entries.file(pad.registryId, Entry(lane: lane, interface: nil, reads: nil))
        events?.arrived(HidPadArrival(slotId: pad.slotId, lane: lane, probe: .neverListed))
        events?.refused(pad.slotId, .busy)
    }

    private func removed(_ registryId: UInt64) {
        guard let entry = entries.remove(registryId) else { return }
        end(entry)
    }

    /// The device stays known, so a read that failed is not opened again
    /// until the pad comes back.
    private func readFailed(_ slotId: String, _ status: IOReturn) {
        guard let entry = entries.release(where: { $0.lane.slotId == slotId }) else { return }
        Self.log.error("XUSB read failed id=\(slotId, privacy: .public) status=\(status)")
        end(entry)
    }

    private func end(_ entry: Entry) {
        entry.interface?.close()
        entry.lane.output?.deviceGone()
        events?.removed(entry.lane.slotId)
    }
}

/// A pad the reader is opening: what its lane is made of.
private struct XusbArrivingPad {
    let registryId: UInt64
    let slotId: String
    let candidate: HidPadCandidate
    let wiring: HidPadWiring

    func lane(output: DirectOutput?) -> HidPadLane {
        HidPadLane(slotId: slotId, candidate: candidate, wiring: wiring, openedNs: DispatchTime.now().uptimeNanoseconds, output: output)
    }
}

/// IOUSBHost reports a failure as an NSError whose code is the IOReturn.
func ioReturn(of error: Error) -> IOReturn {
    IOReturn(truncatingIfNeeded: (error as NSError).code)
}
