// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// One pad's hot-path switches. The main actor sets them; the thread a pad's
// input arrives on (the HID reader's run loop, GameController's input queue)
// reads them once per report and never waits on the main thread.

import DishCore
import Foundation
import os

/// Which source of a pad's input is published, and the "tell me" bits the
/// main actor raises while the pad's input-source machine needs an input
/// event: the pad is unproven, or a "Not responding?" check is running. A
/// change that finds its source's bit raised clears it and posts one event,
/// so a check hears at most one event per source however fast the pad sends.
/// "Check the buttons" listens through the same gate: while its walk is
/// open a generic pad's lane keeps the pad's rest, and a raised wish posts
/// the next raw change once. The word is guarded by an unfair lock rather
/// than an atomic: Swift's `Atomic` needs macOS 15 and Dish runs on 13.
final class PadGate: @unchecked Sendable {
    /// Posts one input event for the pad `key` to the main actor; called on
    /// the hot path's thread, at most once per raised bit.
    typealias Notify = @Sendable (_ key: String, _ source: InputSource) -> Void

    let key: String
    private let notify: Notify
    private var forwarded: InputSource?
    private var tellStandard = false
    private var tellDirect = false
    private var captureOpen = false
    private var captureWished = false
    private var lock = TrackedLock(os_unfair_lock_s(), "input.gate")

    init(key: String, notify: @escaping Notify) {
        self.key = key
        self.notify = notify
    }

    /// One report from `source`: tells the main actor when it asked and the
    /// report changed something, and answers whether to publish it.
    func pass(_ source: InputSource, changed: Bool) -> Bool {
        lock.lock()
        let forwards = forwarded == source
        let tell = changed && takeTell(source)
        lock.unlock()
        if tell { notify(key, source) }
        return forwards
    }

    /// Whether `source` is the published one, for the streams that prove
    /// nothing (motion, touchpad).
    func forwards(_ source: InputSource) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return forwarded == source
    }

    /// The published source; nil publishes nothing.
    var routed: InputSource? {
        lock.lock()
        defer { lock.unlock() }
        return forwarded
    }

    func route(_ source: InputSource?) {
        lock.lock()
        forwarded = source
        lock.unlock()
    }

    /// Raise both bits: the next change on each source posts one event.
    func requestEvents() {
        setTells(true)
    }

    func cancelEvents() {
        setTells(false)
    }

    /// Whether the next change on `source` will post an event.
    func awaitsEvent(_ source: InputSource) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        switch source {
        case .standard: return tellStandard
        case .direct: return tellDirect
        }
    }

    /// Opens the walk if it is not, and wishes for the next raw change.
    func listenForCapture() {
        lock.lock()
        captureOpen = true
        captureWished = true
        lock.unlock()
    }

    func closeCapture() {
        lock.lock()
        captureOpen = false
        captureWished = false
        lock.unlock()
    }

    /// Whether a walk is open, read once per report.
    var capturing: Bool {
        lock.lock()
        defer { lock.unlock() }
        return captureOpen
    }

    /// Reads and lowers the wish: true once per `listenForCapture`.
    func takeCaptureWish() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let wished = captureWished
        captureWished = false
        return wished
    }

    private func setTells(_ raised: Bool) {
        lock.lock()
        tellStandard = raised
        tellDirect = raised
        lock.unlock()
    }

    /// Reads and lowers the source's bit; the caller holds the lock.
    private func takeTell(_ source: InputSource) -> Bool {
        switch source {
        case .standard:
            let raised = tellStandard
            tellStandard = false
            return raised
        case .direct:
            let raised = tellDirect
            tellDirect = false
            return raised
        }
    }
}
