// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// One Steam Controller's writes, on a serial queue of their own so the HID
// reader's thread never waits on a USB transfer: the plan's configuration
// when Dish starts reading the pad and when a receiver's slot gains its
// controller, the restore on every release, the 2026 pad's lizard-mode
// refresh (its firmware's watchdog turns lizard mode back on) and its
// rumble, re-sent inside the firmware's safety stop until the host's hold
// ends. A feature write the wireless receiver refuses under load is retried
// a bounded number of times, as SDL and hid-steam retry it.

import DishCore
import Foundation
import IOKit.hid
import os

/// What a lane sends its pad. Every call returns at once; the work runs on
/// the output's own queue.
protocol DirectOutput: AnyObject, Sendable {
    /// Dish starts reading the pad.
    func claimed()
    /// A controller arrived on the interface, fresh from a boot.
    func controllerConnected()
    /// A receiver's slot lost its controller.
    func controllerLeft()
    /// The host's rumble, from the feedback queue.
    func rumble(strong: UInt16, weak: UInt16, durationMs: UInt16)
    /// Dish stops reading the pad: it is given back as it came.
    func release()
    /// The device left: nothing more is sent.
    func deviceGone()
    /// The app is quitting: the release has run when this returns.
    func releaseNow()
}

/// One report onto the device; the IOKit writer in the app, a recorder in tests.
protocol HidReportWriting: AnyObject, Sendable {
    func write(_ report: SteamWrite) -> IOReturn
}

final class IOKitReportWriter: HidReportWriting, @unchecked Sendable {
    private let device: IOHIDDevice

    init(device: IOHIDDevice) {
        self.device = device
    }

    func write(_ report: SteamWrite) -> IOReturn {
        var bytes = report.bytes
        let kind = report.kind == .feature ? kIOHIDReportTypeFeature : kIOHIDReportTypeOutput
        blockingRegion("steam.setReport")
        return IOHIDDeviceSetReport(device, kind, CFIndex(report.reportId), &bytes, bytes.count)
    }
}

final class SteamOutput: DirectOutput, @unchecked Sendable {
    static let log = Logger(subsystem: "com.tinkernorth.dish", category: "Direct")
    /// The desktops' budget: a receiver under load refuses a feature write
    /// for a moment, and even a dead one finishes well inside a second.
    static let featureAttempts = 25
    static let featureRetryMs = 20

    private let slotId: String
    private let plan: SteamPlan
    private let writer: HidReportWriting
    private let queue: DispatchQueue
    /// Read only on the queue.
    private let clockMs: () -> Int64
    private let refreshMs: Int64

    // Owned by the queue.
    private var reading = false
    private var connected: Bool
    private var rumbleLevel = TritonRumble()
    private var refreshTimer: DispatchSourceTimer?
    private var rumbleTimer: DispatchSourceTimer?

    init(
        slotId: String,
        plan: SteamPlan,
        writer: HidReportWriting,
        clockMs: @escaping () -> Int64 = uptimeMs,
        refreshMs: Int64 = TritonRumbleRule.lizardRefreshMs
    ) {
        self.slotId = slotId
        self.plan = plan
        self.writer = writer
        self.clockMs = clockMs
        self.refreshMs = refreshMs
        queue = DispatchQueue(label: "com.tinkernorth.dish.steam.\(slotId)", qos: .userInitiated)
        connected = !plan.receiver
    }

    deinit {
        refreshTimer?.cancel()
        rumbleTimer?.cancel()
    }

    func claimed() {
        queue.async { self.claimOnQueue() }
    }

    func controllerConnected() {
        queue.async { self.connectOnQueue() }
    }

    func controllerLeft() {
        queue.async { self.leaveOnQueue() }
    }

    func rumble(strong: UInt16, weak: UInt16, durationMs: UInt16) {
        queue.async { self.rumbleOnQueue(strong: strong, weak: weak, durationMs: durationMs) }
    }

    func release() {
        queue.async { self.releaseOnQueue() }
    }

    func deviceGone() {
        queue.async { self.goneOnQueue() }
    }

    func releaseNow() {
        queue.sync { self.releaseOnQueue() }
    }

    /// Everything posted before this call has run: the tests' join.
    func drain() {
        queue.sync {}
    }

    // MARK: - On the queue

    /// A pad known to be there is configured at once; a receiver's slot
    /// that holds none yet is asked, or waited on.
    private func claimOnQueue() {
        reading = true
        guard connected else { return send(plan.onClaim) }
        send(plan.onConnect)
        startRefreshing()
    }

    private func connectOnQueue() {
        connected = true
        guard reading else { return }
        send(plan.onConnect)
        startRefreshing()
    }

    private func leaveOnQueue() {
        connected = false
        stopTimers()
    }

    /// The 2015 pad has no motors; a pad not read, or a slot with no
    /// controller, takes nothing.
    private func rumbleOnQueue(strong: UInt16, weak: UInt16, durationMs: UInt16) {
        guard plan.rumbles, reading, connected else { return }
        let report = rumbleLevel.command(strong: strong, weak: weak, durationMs: durationMs, nowMs: clockMs())
        sendRumble(report)
        guard rumbleLevel.running else { return stopRumbleTimer() }
        startRumbleTimer()
    }

    /// A slot with no controller has nothing to restore.
    private func releaseOnQueue() {
        guard reading else { return }
        reading = false
        stopTimers()
        guard connected else { return }
        send(plan.onRelease)
    }

    private func goneOnQueue() {
        reading = false
        stopTimers()
    }

    // MARK: - The timers

    private func startRefreshing() {
        guard plan.refreshesLizardMode, refreshTimer == nil else { return }
        refreshTimer = repeating(everyMs: refreshMs) { [weak self] in self?.refreshTick() }
    }

    private func refreshTick() {
        send(plan.refresh)
    }

    private func startRumbleTimer() {
        guard rumbleTimer == nil else { return }
        rumbleTimer = repeating(everyMs: TritonRumbleRule.resendMs) { [weak self] in self?.rumbleTick() }
    }

    /// The level again inside the safety stop, and the stop once its hold ends.
    private func rumbleTick() {
        if let report = rumbleLevel.tick(nowMs: clockMs()) { sendRumble(report) }
        guard !rumbleLevel.running else { return }
        stopRumbleTimer()
    }

    private func stopRumbleTimer() {
        rumbleTimer?.cancel()
        rumbleTimer = nil
    }

    private func stopTimers() {
        refreshTimer?.cancel()
        refreshTimer = nil
        stopRumbleTimer()
        rumbleLevel = TritonRumble()
    }

    private func repeating(everyMs: Int64, _ work: @escaping () -> Void) -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let interval = DispatchTimeInterval.milliseconds(Int(everyMs))
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler(handler: work)
        timer.resume()
        return timer
    }

    // MARK: - The writes

    private func send(_ writes: [SteamWrite]) {
        for write in writes {
            switch write.kind {
            case .feature: sendFeature(write)
            case .output: sendOutput(write)
            }
        }
    }

    /// Retried while the device refuses it; the last refusal is logged.
    private func sendFeature(_ write: SteamWrite) {
        var status = writer.write(write)
        var attempt = 1
        while status != kIOReturnSuccess, attempt < Self.featureAttempts {
            Thread.sleep(forTimeInterval: TimeInterval(Self.featureRetryMs) / 1000)
            status = writer.write(write)
            attempt += 1
        }
        guard status != kIOReturnSuccess else { return }
        Self.log.error("STEAM write id=\(self.slotId, privacy: .public) report=\(write.reportId) status=\(status)")
    }

    private func sendRumble(_ report: [UInt8]) {
        sendOutput(SteamWrite(kind: .output, reportId: TritonReportId.hapticRumble, bytes: report))
    }

    /// An output report is never retried: the next re-send heals a dropped one.
    private func sendOutput(_ write: SteamWrite) {
        let status = writer.write(write)
        guard status != kIOReturnSuccess else { return }
        Self.log.error("STEAM output id=\(self.slotId, privacy: .public) report=\(write.reportId) status=\(status)")
    }
}
