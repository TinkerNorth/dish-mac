// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// One pad's hot-path switches. The main actor sets them; the thread a pad's
// input arrives on (the HID reader's run loop, GameController's input queue)
// reads them once per report and never waits on the main thread.

import DishCore
import Foundation

/// Which source of a pad's input is published, and the "tell me" bits the
/// main actor raises while the pad's input-source machine needs an input
/// event: the pad is unproven, or a "Not responding?" check is running. A
/// change that finds its source's bit raised clears it and posts one event,
/// so a check hears at most one event per source however fast the pad sends.
/// "Check the buttons" listens through the same gate: while its walk is
/// open a generic pad's lane keeps the pad's rest, and a raised wish posts
/// the next raw change once. Every switch is a bit of one atomic word: the
/// main actor sets them, the pad's thread reads them and takes the bits it
/// spends with a compare-exchange.
final class PadGate: @unchecked Sendable {
    /// Posts one input event for the pad `key` to the main actor; called on
    /// the hot path's thread, at most once per raised bit.
    typealias Notify = @Sendable (_ key: String, _ source: InputSource) -> Void

    let key: String
    private let notify: Notify
    private let word = AtomicWord.allocate()

    init(key: String, notify: @escaping Notify) {
        self.key = key
        self.notify = notify
    }

    deinit {
        word.deallocate()
    }

    /// One report from `source`: tells the main actor when it asked and the
    /// report changed something, and answers whether to publish it.
    func pass(_ source: InputSource, changed: Bool) -> Bool {
        let forwards = GateWord.forwarded(word.load()) == source
        if changed, take(GateWord.tell(source)) { notify(key, source) }
        return forwards
    }

    /// Whether `source` is the published one, for the streams that prove
    /// nothing (motion, touchpad).
    func forwards(_ source: InputSource) -> Bool {
        GateWord.forwarded(word.load()) == source
    }

    /// The published source; nil publishes nothing.
    var routed: InputSource? {
        GateWord.forwarded(word.load())
    }

    func route(_ source: InputSource?) {
        update { GateWord.withForwarded(source, in: $0) }
    }

    /// Raise both bits: the next change on each source posts one event.
    func requestEvents() {
        update { $0 | GateWord.tells }
    }

    func cancelEvents() {
        update { $0 & ~GateWord.tells }
    }

    /// Whether the next change on `source` will post an event.
    func awaitsEvent(_ source: InputSource) -> Bool {
        word.load() & GateWord.tell(source) != 0
    }

    /// Opens the walk if it is not, and wishes for the next raw change.
    func listenForCapture() {
        update { $0 | GateWord.captureOpen | GateWord.captureWished }
    }

    func closeCapture() {
        update { $0 & ~(GateWord.captureOpen | GateWord.captureWished) }
    }

    /// Whether a walk is open, read once per report.
    var capturing: Bool {
        word.load() & GateWord.captureOpen != 0
    }

    /// Reads and lowers the wish: true once per `listenForCapture`.
    func takeCaptureWish() -> Bool {
        take(GateWord.captureWished)
    }

    /// Lowers `bit` if it is raised; true for the one caller that lowered it.
    private func take(_ bit: Int64) -> Bool {
        var seen = word.load()
        while seen & bit != 0 {
            if word.compareExchange(expected: seen, desired: seen & ~bit) { return true }
            seen = word.load()
        }
        return false
    }

    private func update(_ change: (Int64) -> Int64) {
        var seen = word.load()
        while !word.compareExchange(expected: seen, desired: change(seen)) {
            seen = word.load()
        }
    }
}

/// The gate's word: the forwarded source in the low two bits, then the two
/// tell bits and the walk's two.
enum GateWord {
    static let sourceMask: Int64 = 0b11
    static let tells: Int64 = tell(.standard) | tell(.direct)
    static let captureOpen: Int64 = 1 << 4
    static let captureWished: Int64 = 1 << 5

    static func tell(_ source: InputSource) -> Int64 {
        switch source {
        case .standard: 1 << 2
        case .direct: 1 << 3
        }
    }

    static func forwarded(_ word: Int64) -> InputSource? {
        switch word & sourceMask {
        case 1: .standard
        case 2: .direct
        default: nil
        }
    }

    static func withForwarded(_ source: InputSource?, in word: Int64) -> Int64 {
        let code: Int64 = switch source {
        case .standard?: 1
        case .direct?: 2
        case nil: 0
        }
        return word & ~sourceMask | code
    }
}
