// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// The Direct reader: one IOHIDManager on a thread of its own, whose run loop
// carries every Direct pad's report callback, so input never waits behind
// the main thread. Each device is opened with kIOHIDOptionsTypeNone: Dish
// reads the reports alongside macOS and never seizes the device (seizing a
// game controller is not possible through public API, and would blind
// GameController). Enumerating and reading gamepad usages needs no Input
// Monitoring permission and no entitlement, so no access is ever requested.

import DishCore
import Foundation
import GameController
import IOKit.hid
import os

/// GameController's answer for one device, asked on the main actor.
struct GameControllerProbe: @unchecked Sendable {
    /// Whether the framework will vend a controller for the device.
    let supports: @MainActor () -> Bool

    /// `GCController.supportsHIDDevice` over a device the reader holds.
    static func live(_ device: IOHIDDevice) -> GameControllerProbe {
        GameControllerProbe { GCController.supportsHIDDevice(device) }
    }
}

/// A device the reader opened, as the main actor first hears of it.
struct HidPadArrival {
    let slotId: String
    let lane: HidPadLane
    let probe: GameControllerProbe

    var candidate: HidPadCandidate {
        lane.candidate
    }
}

/// What the reader tells the main actor, each call already on it.
struct HidPadEvents {
    let arrived: @Sendable (HidPadArrival) -> Void
    let removed: @Sendable (_ slotId: String) -> Void
}

/// The reader's seam: IOKit in the app, a fake in tests, nothing at all in
/// a test that builds the composition root.
protocol HidPadReading: AnyObject, Sendable {
    /// Starts reading; each lane publishes through `wiring`.
    func start(wiring: HidPadWiring, events: HidPadEvents)
    /// Stops reading one pad GameController turned out to read.
    func release(slotId: String)
}

/// Reads nothing: the composition root's default outside the app.
final class InertHidPadReader: HidPadReading {
    init() {}

    func start(wiring: HidPadWiring, events: HidPadEvents) {}

    func release(slotId: String) {}
}

final class IOKitHidPadReader: HidPadReading, @unchecked Sendable {
    static let log = Logger(subsystem: "com.tinkernorth.dish", category: "Direct")
    static let threadName = "com.tinkernorth.dish.hid"
    /// How often the lanes are checked against the devices macOS lists.
    static let reconcileSeconds: CFTimeInterval = 1

    private struct Entry {
        let device: IOHIDDevice
        let lane: HidPadLane
    }

    /// The reader thread's run loop, once it runs.
    private let runLoopBox = LockedBox<CFRunLoop?>(nil)
    private let started = AtomicBool(false)

    // Touched only on the reader's thread.
    private var manager: IOHIDManager?
    private var entries = HidEntryRegistry<Entry>()
    private var wiring: HidPadWiring?
    private var events: HidPadEvents?

    init() {}

    func start(wiring: HidPadWiring, events: HidPadEvents) {
        guard !started.getAndSet(true) else { return }
        let thread = Thread { [self] in run(wiring: wiring, events: events) }
        thread.name = Self.threadName
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    func release(slotId: String) {
        perform { [self] in releaseOnThread(slotId) }
    }

    /// The thread's whole life: the manager scheduled on its run loop, then
    /// the run loop until the process ends.
    private func run(wiring: HidPadWiring, events: HidPadEvents) {
        self.wiring = wiring
        self.events = events
        guard let runLoop = CFRunLoopGetCurrent() else { return }
        runLoopBox.set(runLoop)
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerSetDeviceMatchingMultiple(manager, hidPadMatching() as CFArray)
        IOHIDManagerRegisterDeviceMatchingCallback(manager, hidPadMatched, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, hidPadRemoved, context)
        IOHIDManagerScheduleWithRunLoop(manager, runLoop, CFRunLoopMode.defaultMode.rawValue)
        self.manager = manager
        scheduleReconcile(on: runLoop)
        CFRunLoopRun()
    }

    /// The reconcile runs on the reader's own run loop, beside the
    /// manager's callbacks, so the entries stay single-threaded.
    private func scheduleReconcile(on runLoop: CFRunLoop) {
        let firstFire = CFAbsoluteTimeGetCurrent() + Self.reconcileSeconds
        let timer = CFRunLoopTimerCreateWithHandler(kCFAllocatorDefault, firstFire, Self.reconcileSeconds, 0, 0) { [weak self] _ in
            self?.reconcile()
        }
        CFRunLoopAddTimer(runLoop, timer, .defaultMode)
    }

    private func perform(_ work: @escaping () -> Void) {
        guard let runLoop = runLoopBox.get() else { return }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue, work)
        CFRunLoopWakeUp(runLoop)
    }

    // MARK: - On the reader's thread

    /// A device that matches several rules arrives once per rule; only its
    /// first reference opens a lane.
    fileprivate func matched(_ device: IOHIDDevice) {
        let registryId = Self.registryId(of: device)
        guard !entries.knows(registryId), let wiring, let events else { return }
        guard let candidate = hidPadCandidate(Self.properties(of: device)) else { return }
        let taken = Set(entries.reading.map(\.lane.slotId))
        let slotId = lowestFreeSlotId(base: directSlotBase(vendorId: candidate.vendorId, productId: candidate.productId), taken: taken)
        let lane = HidPadLane(slotId: slotId, candidate: candidate, wiring: wiring, openedNs: DispatchTime.now().uptimeNanoseconds)
        guard open(device, lane: lane) else { return }
        entries.file(registryId, Entry(device: device, lane: lane))
        events.arrived(HidPadArrival(slotId: slotId, lane: lane, probe: .live(device)))
    }

    /// The lane is retained for the callback until `close` unregisters it.
    private func open(_ device: IOHIDDevice, lane: HidPadLane) -> Bool {
        let status = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard status == kIOReturnSuccess else {
            Self.log.error("DIRECT open failed id=\(lane.slotId, privacy: .public) status=\(status)")
            return false
        }
        let context = Unmanaged.passRetained(lane).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(device, lane.buffer, lane.capacity, hidPadReportCallback, context)
        return true
    }

    /// The device leaves once, whichever of its references reports it.
    fileprivate func removed(_ device: IOHIDDevice) {
        guard let entry = entries.remove(Self.registryId(of: device)) else { return }
        end(entry)
    }

    /// Every lane whose device macOS no longer lists is ended.
    private func reconcile() {
        guard let manager else { return }
        let devices = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>) ?? []
        let present = Set(devices.map(Self.registryId(of:)))
        for entry in entries.reconcile(present: present) {
            end(entry)
        }
    }

    private func end(_ entry: Entry) {
        close(entry)
        events?.removed(entry.lane.slotId)
    }

    /// The device stays known as released, so its other reference never
    /// opens a lane GameController already reads.
    private func releaseOnThread(_ slotId: String) {
        guard let entry = entries.release(where: { $0.lane.slotId == slotId }) else { return }
        close(entry)
    }

    private func close(_ entry: Entry) {
        IOHIDDeviceRegisterInputReportCallback(entry.device, entry.lane.buffer, entry.lane.capacity, nil, nil)
        IOHIDDeviceClose(entry.device, IOOptionBits(kIOHIDOptionsTypeNone))
        Unmanaged.passUnretained(entry.lane).release()
    }

    /// The IORegistry entry behind a reference: the identity every reference
    /// IOHIDManager hands back for one device shares. Should the lookup fail,
    /// the reference's own identity stands in, which reads such a device once
    /// per reference, as before.
    private static func registryId(of device: IOHIDDevice) -> UInt64 {
        var registryId: UInt64 = 0
        let status = IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(device), &registryId)
        let fallback = UInt64(UInt(bitPattern: ObjectIdentifier(device).hashValue))
        return status == KERN_SUCCESS ? registryId : fallback
    }

    private static func properties(of device: IOHIDDevice) -> [String: Any] {
        Dictionary(uniqueKeysWithValues: hidPadPropertyKeys.compactMap { key in
            IOHIDDeviceGetProperty(device, key as CFString).map { (key, $0 as Any) }
        })
    }
}

/// The manager's match callback, on the reader's run loop.
private func hidPadMatched(context: UnsafeMutableRawPointer?, result: IOReturn, sender: UnsafeMutableRawPointer?, device: IOHIDDevice) {
    guard let context else { return }
    Unmanaged<IOKitHidPadReader>.fromOpaque(context).takeUnretainedValue().matched(device)
}

/// The manager's removal callback, on the reader's run loop.
private func hidPadRemoved(context: UnsafeMutableRawPointer?, result: IOReturn, sender: UnsafeMutableRawPointer?, device: IOHIDDevice) {
    guard let context else { return }
    Unmanaged<IOKitHidPadReader>.fromOpaque(context).takeUnretainedValue().removed(device)
}
