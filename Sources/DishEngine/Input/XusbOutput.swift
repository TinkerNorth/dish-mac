// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// One XUSB pad's rumble, on a serial queue of its own so neither the
// feedback queue nor the reader's waits on a USB transfer: each host
// command goes out at once, and since the pad holds a level until it is
// sent another, the stop follows once the command's hold ends, and before
// Dish quits.

import DishCore
import Foundation
import os

final class XusbOutput: DirectOutput, @unchecked Sendable {
    static let log = Logger(subsystem: "com.tinkernorth.dish", category: "Direct")
    /// Six of an Xbox 360 pad's 8 ms OUT polls: room for a report in flight
    /// ahead of the stop, and a pause at quit too short to notice.
    static let quitStopBoundMs = 48

    private let slotId: String
    private let pipe: UsbOutputPipe
    private let quitBoundMs: Int
    private let queue: DispatchQueue
    /// Started and stopped only on the queue.
    private let holdTicker: QueueTicker

    // Owned by the queue.
    /// A level is running, so a stop is owed.
    private var holding = false
    private var gone = false

    init(slotId: String, pipe: UsbOutputPipe, quitBoundMs: Int, holdTicker: QueueTicker = DispatchTicker()) {
        self.slotId = slotId
        self.pipe = pipe
        self.quitBoundMs = quitBoundMs
        self.holdTicker = holdTicker
        queue = DispatchQueue(label: "com.tinkernorth.dish.xusb.\(slotId)", qos: .userInitiated)
    }

    /// Read from its arrival: there is nothing to configure.
    func claimed() {}

    /// A wired pad: no receiver slot gains or loses it.
    func controllerConnected() {}

    func controllerLeft() {}

    func rumble(strong: UInt16, weak: UInt16, durationMs: UInt16) {
        let command = xusbRumbleCommand(strong: strong, weak: weak, durationMs: durationMs)
        queue.async { self.rumbleOnQueue(command) }
    }

    func release() {
        queue.async { self.stillOnQueue() }
    }

    func deviceGone() {
        queue.async { self.goneOnQueue() }
    }

    func releaseNow() {
        let stop = DispatchWorkItem { self.stillOnQueue() }
        queue.async(execute: stop)
        let deadline = DispatchTime.now() + .milliseconds(quitBoundMs)
        let outcome = stop.wait(timeout: deadline)
        guard outcome == .timedOut else { return }
        pipe.abort()
    }

    /// Everything posted before this call has run: the tests' join.
    func drain() {
        queue.sync {}
    }

    // MARK: - On the queue

    private func rumbleOnQueue(_ command: XusbRumbleCommand) {
        guard !gone else { return }
        send(command.report)
        guard let holdMs = command.holdMs else { return endHold() }
        holding = true
        holdTicker.start(everyMs: holdMs, on: queue) { [weak self] in self?.stillOnQueue() }
    }

    /// A pad whose motors are still, or that left, is sent nothing.
    private func stillOnQueue() {
        guard holding, !gone else { return }
        send(xusbRumbleStop)
        endHold()
    }

    private func goneOnQueue() {
        gone = true
        endHold()
    }

    private func endHold() {
        holding = false
        holdTicker.stop()
    }

    private func send(_ report: [UInt8]) {
        let status = pipe.write(report)
        guard status != kIOReturnSuccess else { return }
        Self.log.error("XUSB output id=\(self.slotId, privacy: .public) status=\(status)")
    }
}
