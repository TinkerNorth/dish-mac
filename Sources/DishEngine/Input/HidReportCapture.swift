// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// The device "Help support this controller" records: one IOHIDManager, on a
// thread of its own for the length of one capture, matching the target with
// `GCSyntheticDevice` false. The first device that matches is opened with
// kIOHIDOptionsTypeNone, alongside macOS and Dish's own reader, and never
// seized; its reports land in a preallocated ring the main actor drains.
// Opening a game usage needs no Input Monitoring permission, so none is
// asked for.

import DishCore
import Foundation
import GameController
import IOKit.hid
import os

/// What a capture tells the main actor, each call already on it.
struct HidCaptureEvents {
    let found: @Sendable (SupportDevice) -> Void
    let lost: @Sendable () -> Void
}

/// The capture's seam: IOKit in the app, a fake in tests, nothing at all in
/// a test that builds the composition root.
protocol HidReportCapturing: AnyObject, Sendable {
    /// Ends any capture running, then looks for the device `target` names.
    func start(target: SupportTarget, events: HidCaptureEvents)
    func stop()
    /// The reports since the last drain, oldest first.
    func drain() -> [[UInt8]]
}

/// Opens nothing: the composition root's default outside the app.
final class InertHidReportCapture: HidReportCapturing {
    init() {}

    func start(target: SupportTarget, events: HidCaptureEvents) {}

    func stop() {}

    func drain() -> [[UInt8]] {
        []
    }
}

// MARK: - Which device

/// The properties a capture reads off a device as it opens it.
let supportPropertyKeys = [
    kIOHIDProductKey, kIOHIDManufacturerKey, kIOHIDVendorIDKey, kIOHIDProductIDKey, kIOHIDTransportKey,
    kIOHIDReportDescriptorKey, kIOHIDMaxInputReportSizeKey, kIOHIDGCSyntheticDeviceKey
]

/// A USB identity is matched by IOKit; a name is matched among the game
/// usages and picked by the product string.
func supportMatching(_ target: SupportTarget) -> [[String: Any]] {
    switch target {
    case let .usb(vendorId, productId):
        [[kIOHIDVendorIDKey: Int(vendorId), kIOHIDProductIDKey: Int(productId), kIOHIDGCSyntheticDeviceKey: false]]
    case .named:
        hidCensusMatching()
    }
}

/// The device's facts when it is the one the target names; nil for a
/// synthetic device and for another product.
func supportDevice(_ properties: [String: Any], target: SupportTarget) -> SupportDevice? {
    let synthetic = properties[kIOHIDGCSyntheticDeviceKey] as? Bool == true
    guard !synthetic else { return nil }
    let device = SupportDevice(
        vendorId: UInt16(clamping: properties[kIOHIDVendorIDKey] as? Int ?? 0),
        productId: UInt16(clamping: properties[kIOHIDProductIDKey] as? Int ?? 0),
        product: properties[kIOHIDProductKey] as? String ?? "",
        manufacturer: properties[kIOHIDManufacturerKey] as? String ?? "",
        transport: properties[kIOHIDTransportKey] as? String ?? "",
        descriptor: (properties[kIOHIDReportDescriptorKey] as? Data).map { [UInt8]($0) } ?? []
    )
    return names(target, device) ? device : nil
}

private func names(_ target: SupportTarget, _ device: SupportDevice) -> Bool {
    switch target {
    case let .usb(vendorId, productId): device.vendorId == vendorId && device.productId == productId
    case let .named(name): sameName(device.product, name)
    }
}

private func sameName(_ product: String, _ name: String) -> Bool {
    let trimmed = { (text: String) in text.trimmingCharacters(in: .whitespaces).lowercased() }
    return trimmed(product) == trimmed(name)
}

// MARK: - IOKit

/// One ring for the app's life; each capture is a session of its own, so a
/// session ending on its thread never touches the next one's device.
final class IOKitHidReportCapture: HidReportCapturing, @unchecked Sendable {
    private let ring = HidReportRing()
    private let session = LockedBox<HidCaptureSession?>(nil)

    init() {}

    func start(target: SupportTarget, events: HidCaptureEvents) {
        stop()
        // The ring's leftovers belong to the session that ended.
        _ = ring.drain()
        let next = HidCaptureSession(target: target, events: events, ring: ring)
        session.set(next)
        next.begin()
    }

    func stop() {
        session.get()?.end()
        session.set(nil)
    }

    func drain() -> [[UInt8]] {
        ring.drain()
    }
}

/// One capture's thread, manager and device.
final class HidCaptureSession: @unchecked Sendable {
    static let log = Logger(subsystem: "com.tinkernorth.dish", category: "Direct")
    static let threadName = "com.tinkernorth.dish.hid-capture"

    private let target: SupportTarget
    private let events: HidCaptureEvents
    private let ring: HidReportRing
    private let runLoopBox = LockedBox<CFRunLoop?>(nil)
    private let ended = AtomicBool(false)

    // Touched only on the session's thread.
    private var manager: IOHIDManager?
    private var device: IOHIDDevice?
    private var buffer: UnsafeMutablePointer<UInt8>?
    private var capacity = 0

    init(target: SupportTarget, events: HidCaptureEvents, ring: HidReportRing) {
        self.target = target
        self.events = events
        self.ring = ring
    }

    func begin() {
        let thread = Thread { [self] in run() }
        thread.name = Self.threadName
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    /// The teardown runs on the session's own run loop; a session ended
    /// before its thread ran never opens anything.
    func end() {
        ended.set(true)
        guard let runLoop = runLoopBox.get() else { return }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue) { [self] in tearDown() }
        CFRunLoopWakeUp(runLoop)
    }

    /// The thread's whole life, which also keeps the session alive for the
    /// callbacks' unretained context: the manager scheduled on its run loop,
    /// then the run loop until `end` tears it down.
    private func run() {
        guard let runLoop = CFRunLoopGetCurrent() else { return }
        runLoopBox.set(runLoop)
        guard !ended.get() else { return }
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerSetDeviceMatchingMultiple(manager, supportMatching(target) as CFArray)
        IOHIDManagerRegisterDeviceMatchingCallback(manager, supportDeviceMatched, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, supportDeviceRemoved, context)
        IOHIDManagerScheduleWithRunLoop(manager, runLoop, CFRunLoopMode.defaultMode.rawValue)
        self.manager = manager
        CFRunLoopRun()
    }

    // MARK: - On the session's thread

    fileprivate func matched(_ candidate: IOHIDDevice) {
        guard device == nil, let facts = supportDevice(Self.properties(of: candidate), target: target) else { return }
        let status = IOHIDDeviceOpen(candidate, IOOptionBits(kIOHIDOptionsTypeNone))
        guard status == kIOReturnSuccess else {
            Self.log.error("CAPTURE open failed vidpid=\(facts.hardwareKey, privacy: .public) status=\(status)")
            return
        }
        let declared = IOHIDDeviceGetProperty(candidate, kIOHIDMaxInputReportSizeKey as CFString) as? Int ?? 0
        let size = max(declared, HidPadLimits.minimumReportCapacity)
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
        buffer.initialize(repeating: 0, count: size)
        self.buffer = buffer
        capacity = size
        device = candidate
        IOHIDDeviceRegisterInputReportCallback(candidate, buffer, size, supportReportArrived, Unmanaged.passUnretained(self).toOpaque())
        Self.log.info("CAPTURE opened vidpid=\(facts.hardwareKey, privacy: .public)")
        events.found(facts)
    }

    fileprivate func removed(_ gone: IOHIDDevice) {
        guard gone == device else { return }
        closeDevice()
        events.lost()
    }

    /// One report, copied into the ring: no allocation.
    fileprivate func received(_ report: UnsafeMutablePointer<UInt8>, length: Int) {
        ring.write(UnsafeBufferPointer(start: report, count: min(length, capacity)))
    }

    private func closeDevice() {
        guard let device, let buffer else { return }
        IOHIDDeviceRegisterInputReportCallback(device, buffer, capacity, nil, nil)
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        buffer.deallocate()
        self.buffer = nil
        self.device = nil
        capacity = 0
    }

    private func tearDown() {
        closeDevice()
        if let manager {
            IOHIDManagerRegisterDeviceMatchingCallback(manager, nil, nil)
            IOHIDManagerRegisterDeviceRemovalCallback(manager, nil, nil)
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        }
        manager = nil
        CFRunLoopStop(CFRunLoopGetCurrent())
    }

    private static func properties(of device: IOHIDDevice) -> [String: Any] {
        Dictionary(uniqueKeysWithValues: supportPropertyKeys.compactMap { key in
            IOHIDDeviceGetProperty(device, key as CFString).map { (key, $0 as Any) }
        })
    }
}

/// The manager's match callback, on the capture's run loop.
private func supportDeviceMatched(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    device: IOHIDDevice
) {
    guard let context else { return }
    Unmanaged<HidCaptureSession>.fromOpaque(context).takeUnretainedValue().matched(device)
}

/// The manager's removal callback, on the capture's run loop.
private func supportDeviceRemoved(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    device: IOHIDDevice
) {
    guard let context else { return }
    Unmanaged<HidCaptureSession>.fromOpaque(context).takeUnretainedValue().removed(device)
}

/// The device's input-report callback, on the capture's run loop.
private func supportReportArrived(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    type: IOHIDReportType,
    reportId: UInt32,
    report: UnsafeMutablePointer<UInt8>,
    length: CFIndex
) {
    guard let context else { return }
    Unmanaged<HidCaptureSession>.fromOpaque(context).takeUnretainedValue().received(report, length: Int(length))
}
