// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Foundation

/// Calls back on a queue every so often until stopped: the seam between a
/// cadence and the clock, so a test fires the ticks by hand.
protocol QueueTicker: AnyObject, Sendable {
    /// Starts, or restarts, the cadence: the first tick comes one period on.
    func start(everyMs: Int64, on queue: DispatchQueue, _ tick: @escaping @Sendable () -> Void)
    func stop()
}

/// The production ticker: a repeating dispatch timer on the queue. Its one
/// field is touched only from that queue, which is its whole thread safety.
final class DispatchTicker: QueueTicker, @unchecked Sendable {
    private var timer: DispatchSourceTimer?

    init() {}

    deinit {
        timer?.cancel()
    }

    func start(everyMs: Int64, on queue: DispatchQueue, _ tick: @escaping @Sendable () -> Void) {
        stop()
        let source = DispatchSource.makeTimerSource(queue: queue)
        let period = DispatchTimeInterval.milliseconds(Int(everyMs))
        source.schedule(deadline: .now() + period, repeating: period)
        source.setEventHandler(handler: tick)
        source.resume()
        timer = source
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }
}
