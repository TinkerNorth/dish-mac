// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// The Direct reader: one IOHIDManager on a thread of its own, whose run loop
// carries every Direct pad's report callback, so input never waits behind
// the main thread. Each device is opened with kIOHIDOptionsTypeNone: Dish
// reads the reports alongside macOS and never seizes the device (seizing a
// game controller is not possible through public API, and would blind
// GameController). Enumerating and reading gamepad usages needs no Input
// Monitoring permission and no entitlement, so no access is asked for them.
// Dish sends a Switch pad whose full reports have not arrived the start
// sequence (the USB handshake at 3 Mbit, the timeout disable, full report
// mode and the IMU enable): macOS's driver leaves the Pro and the N64 silent. A Steam
// Controller is opened only once the user picks Direct, since reading it
// turns its keyboard and mouse off, and the 2026 pad's one interface
// carries its keyboard and mouse, so macOS asks for Input Monitoring before
// it opens: the standing is read first, and the user asked off this thread,
// since asking blocks until they answer. A Steam Controller's writes run on
// its own output's queue, never here.

import DishCore
import Foundation
import GameController
import IOKit.hid
import IOKit.hidsystem
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

/// Why macOS would not let Dish open a pad it was asked to read.
package enum ClaimRefusal: Equatable {
    /// Its collections include a keyboard or a mouse, and Dish has no Input
    /// Monitoring permission.
    case inputMonitoring
    /// Another app holds it, or it would not open.
    case busy
}

/// `IOHIDDeviceOpen`'s answer as the user reads it.
func claimRefusal(_ status: IOReturn) -> ClaimRefusal {
    status == kIOReturnNotPermitted ? .inputMonitoring : .busy
}

/// What the reader tells the main actor, each call already on it.
struct HidPadEvents {
    let arrived: @Sendable (HidPadArrival) -> Void
    let removed: @Sendable (_ slotId: String) -> Void
    /// A claimed pad would not open.
    var refused: @Sendable (_ slotId: String, _ refusal: ClaimRefusal) -> Void = ignoreRefusal
}

/// Nobody listening for a refusal.
@Sendable
func ignoreRefusal(_: String, _: ClaimRefusal) {}

/// The reader's seam: IOKit in the app, a fake in tests, nothing at all in
/// a test that builds the composition root.
protocol HidPadReading: AnyObject, Sendable {
    /// Starts reading; each lane publishes through `wiring`.
    func start(wiring: HidPadWiring, events: HidPadEvents)
    /// Stops reading one pad GameController turned out to read.
    func release(slotId: String)
    /// Opens an opt-in pad the user picked Direct for, and starts its output.
    func claim(slotId: String)
    /// Gives an opt-in pad back as it came; it stays open for a later claim.
    func unclaim(slotId: String)
}

/// Reads nothing: the composition root's default outside the app.
final class InertHidPadReader: HidPadReading {
    init() {}

    func start(wiring: HidPadWiring, events: HidPadEvents) {}

    func release(slotId: String) {}

    func claim(slotId: String) {}

    func unclaim(slotId: String) {}
}

final class IOKitHidPadReader: HidPadReading, @unchecked Sendable {
    static let log = Logger(subsystem: "com.tinkernorth.dish", category: "Direct")
    static let threadName = "com.tinkernorth.dish.hid"
    /// How often the lanes are checked against the devices macOS lists.
    static let reconcileSeconds: CFTimeInterval = 1
    /// How often a Switch pad's stream is checked; the start sequence goes
    /// out one packet per tick, so starting one pad never stalls another's
    /// reports behind a sleep.
    static let streamWatchSeconds: CFTimeInterval = 0.25
    private static let nsPerMs: UInt64 = 1_000_000

    private struct Entry {
        let device: IOHIDDevice
        let lane: HidPadLane
    }

    /// The reader thread's run loop, once it runs.
    private let runLoopBox = LockedBox<CFRunLoop?>(nil, name: "direct.runLoop")
    private let started = AtomicBool(false)

    // Touched only on the reader's thread.
    private var manager: IOHIDManager?
    private var entries = HidEntryRegistry<Entry>()
    /// The start sequence's watch per Switch lane, by slot id.
    private var watches: [String: SwitchStreamWatch] = [:]
    /// The opt-in lanes a claim opened, by slot id; every other lane opens
    /// as it arrives.
    private var opened: Set<String> = []
    /// Asking for Input Monitoring blocks until the user answers
    /// (`IOHIDRequestAccess` waits on TCC with no timeout), so it runs here,
    /// never on the reader's thread.
    private let accessQueue = DispatchQueue(label: "com.tinkernorth.dish.hid.access", qos: .userInitiated)
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

    func claim(slotId: String) {
        perform { [self] in claimOnThread(slotId, asked: false) }
    }

    func unclaim(slotId: String) {
        perform { [self] in unclaimOnThread(slotId) }
    }

    /// The thread's whole life: the manager scheduled on its run loop, then
    /// the run loop until the process ends.
    private func run(wiring: HidPadWiring, events: HidPadEvents) {
        ThreadRole.hidReader.enterThread()
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
        scheduleStreamWatch(on: runLoop)
        CFRunLoopRun()
    }

    private func scheduleStreamWatch(on runLoop: CFRunLoop) {
        let firstFire = CFAbsoluteTimeGetCurrent() + Self.streamWatchSeconds
        let timer = CFRunLoopTimerCreateWithHandler(kCFAllocatorDefault, firstFire, Self.streamWatchSeconds, 0, 0) { [weak self] _ in
            self?.tickStreams()
        }
        CFRunLoopAddTimer(runLoop, timer, .defaultMode)
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
        let output = candidate.steamPlan.map { SteamOutput(slotId: slotId, plan: $0, writer: IOKitReportWriter(device: device)) }
        let openedNs = DispatchTime.now().uptimeNanoseconds
        let lane = HidPadLane(slotId: slotId, candidate: candidate, wiring: wiring, openedNs: openedNs, output: output)
        let waitsForAClaim = candidate.model?.rule == .optIn
        guard waitsForAClaim || open(device, lane: lane) else { return }
        entries.file(registryId, Entry(device: device, lane: lane))
        startWatching(lane)
        events.arrived(HidPadArrival(slotId: slotId, lane: lane, probe: .live(device)))
    }

    // MARK: - An opt-in pad

    /// The open is where macOS would ask for Input Monitoring, so the
    /// standing is read first, without a prompt: the device opens only when
    /// no prompt can come of it, the user is asked off this thread, and a
    /// refusal goes to the main actor.
    private func claimOnThread(_ slotId: String, asked: Bool) {
        guard let entry = entries.reading.first(where: { $0.lane.slotId == slotId }) else { return }
        if opened.contains(slotId) {
            entry.lane.output?.claimed()
            return
        }
        let needsInputMonitoring = entry.lane.candidate.needsInputMonitoring
        let access = needsInputMonitoring ? Self.inputMonitoringAccess() : .granted
        switch claimStep(needsInputMonitoring: needsInputMonitoring, access: access, asked: asked) {
        case .open: openClaimed(entry)
        case .ask: askForInputMonitoring(slotId)
        case .refuse: refuse(entry, .inputMonitoring)
        }
    }

    /// The answer is read back on the reader's thread, which decides again.
    private func askForInputMonitoring(_ slotId: String) {
        accessQueue.async { [self] in
            // The grant is read again through IOHIDCheckAccess once back on the reader's thread.
            _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
            perform { [self] in claimOnThread(slotId, asked: true) }
        }
    }

    private func openClaimed(_ entry: Entry) {
        let status = openStatus(entry.device, lane: entry.lane)
        guard status == kIOReturnSuccess else { return refuse(entry, claimRefusal(status)) }
        opened.insert(entry.lane.slotId)
        entry.lane.output?.claimed()
    }

    private func refuse(_ entry: Entry, _ refusal: ClaimRefusal) {
        let word = String(describing: refusal)
        Self.log.error("DIRECT claim refused id=\(entry.lane.slotId, privacy: .public) refusal=\(word, privacy: .public)")
        events?.refused(entry.lane.slotId, refusal)
    }

    /// `IOHIDCheckAccess` reads the standing without prompting.
    private static func inputMonitoringAccess() -> InputMonitoringAccess {
        blockingRegion("direct.checkAccess")
        switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
        case kIOHIDAccessTypeGranted: return .granted
        case kIOHIDAccessTypeDenied: return .denied
        default: return .undecided
        }
    }

    private func unclaimOnThread(_ slotId: String) {
        guard let entry = entries.reading.first(where: { $0.lane.slotId == slotId }) else { return }
        entry.lane.output?.release()
    }

    private func startWatching(_ lane: HidPadLane) {
        guard lane.startsWithSwitchSequence else { return }
        watches[lane.slotId] = SwitchStreamWatch(openedMs: Self.nowMs())
    }

    // MARK: - The Switch start sequence

    private func tickStreams() {
        let nowMs = Self.nowMs()
        for entry in entries.reading where entry.lane.startsWithSwitchSequence {
            watchStream(entry, nowMs: nowMs)
        }
    }

    private func watchStream(_ entry: Entry, nowMs: Int64) {
        let slotId = entry.lane.slotId
        guard var watch = watches[slotId] else { return }
        let lastFullReportMs = entry.lane.lastFullReportNs.map(Self.ms)
        switch watch.due(lastFullReportMs: lastFullReportMs, nowMs: nowMs) {
        case .streaming:
            watch.noteStreaming()
        case .wait:
            break
        case let .send(step):
            send(step, to: entry)
            watch.noteSent(step, nowMs: nowMs)
        }
        watches[slotId] = watch
    }

    /// One packet of the sequence as an output report; a refusal is logged,
    /// and the watch sends the sequence again on its own schedule.
    private func send(_ step: SwitchStartStep, to entry: Entry) {
        var packet = switchStartPacket(step)
        let reportId = CFIndex(switchStartReportId(step))
        blockingRegion("direct.setReport")
        let status = IOHIDDeviceSetReport(entry.device, kIOHIDReportTypeOutput, reportId, &packet, packet.count)
        let slotId = entry.lane.slotId
        let stepName = String(describing: step)
        Self.log.info("DIRECT start id=\(slotId, privacy: .public) step=\(stepName, privacy: .public) status=\(status)")
    }

    private static func nowMs() -> Int64 {
        ms(DispatchTime.now().uptimeNanoseconds)
    }

    private static func ms(_ ns: UInt64) -> Int64 {
        Int64(ns / nsPerMs)
    }

    private func open(_ device: IOHIDDevice, lane: HidPadLane) -> Bool {
        let status = openStatus(device, lane: lane)
        guard status == kIOReturnSuccess else {
            Self.log.error("DIRECT open failed id=\(lane.slotId, privacy: .public) status=\(status)")
            return false
        }
        return true
    }

    /// The lane is retained for the callback until `close` unregisters it.
    private func openStatus(_ device: IOHIDDevice, lane: HidPadLane) -> IOReturn {
        let status = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard status == kIOReturnSuccess else { return status }
        let context = Unmanaged.passRetained(lane).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(device, lane.buffer, lane.capacity, hidPadReportCallback, context)
        return status
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

    /// A lane that stops being read takes its start sequence's watch with it.
    private func forgetWatch(_ entry: Entry) {
        watches.removeValue(forKey: entry.lane.slotId)
    }

    /// The device stays known as released, so its other reference never
    /// opens a lane GameController already reads.
    private func releaseOnThread(_ slotId: String) {
        guard let entry = entries.release(where: { $0.lane.slotId == slotId }) else { return }
        close(entry)
    }

    /// An opt-in lane no claim opened has nothing to close.
    private func close(_ entry: Entry) {
        forgetWatch(entry)
        entry.lane.output?.deviceGone()
        let slotId = entry.lane.slotId
        let wasOpen = entry.lane.candidate.model?.rule != .optIn || opened.contains(slotId)
        opened.remove(slotId)
        guard wasOpen else { return }
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
