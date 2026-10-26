// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// The live figures Home and Controllers show: events and sends per second,
// the total sent, and each pad's report and motion rates for its wire line
// and card. Read off the processor's tally and the router's send count at
// 1 Hz while a page that shows them is on screen; nothing is measured twice.

import Combine
import DishCore
import DishKernel
import Foundation

/// One pad's rates, quantized as the inspector's are.
package struct PadRates: Equatable {
    package let reportHz: Int
    package let motionHz: Int

    package init(reportHz: Int, motionHz: Int) {
        self.reportHz = reportHz
        self.motionHz = motionHz
    }
}

package struct InputTelemetry: Equatable {
    package var eventsPerSecond = 0
    package var sendsPerSecond = 0
    package var totalSent: UInt64 = 0
    package var pads: [String: PadRates] = [:]

    package init(eventsPerSecond: Int = 0, sendsPerSecond: Int = 0, totalSent: UInt64 = 0, pads: [String: PadRates] = [:]) {
        self.eventsPerSecond = eventsPerSecond
        self.sendsPerSecond = sendsPerSecond
        self.totalSent = totalSent
        self.pads = pads
    }
}

/// The absolute counters at one instant.
struct InputCounts: Equatable {
    var reports: [String: UInt64] = [:]
    var motion: [String: UInt64] = [:]
    var sends: UInt64 = 0
}

/// One rate tracker per stream, so a sample turns counts into rates; a pad
/// that left drops out.
struct TelemetryRates {
    private var reports: [String: InputRateTracker] = [:]
    private var motion: [String: InputRateTracker] = [:]
    private var sends = InputRateTracker()

    mutating func sample(_ counts: InputCounts, nowUs: UInt64) -> InputTelemetry {
        let padIds = Set(counts.reports.keys).union(counts.motion.keys)
        reports = reports.filter { padIds.contains($0.key) }
        motion = motion.filter { padIds.contains($0.key) }
        var pads: [String: PadRates] = [:]
        for id in padIds {
            let reportHz = reports[id, default: InputRateTracker()].sample(count: counts.reports[id] ?? 0, nowUs: nowUs)
            let motionHz = motion[id, default: InputRateTracker()].sample(count: counts.motion[id] ?? 0, nowUs: nowUs)
            pads[id] = PadRates(reportHz: reportHz, motionHz: motionHz)
        }
        let sendsHz = sends.sample(count: counts.sends, nowUs: nowUs)
        let events = pads.values.map(\.reportHz).reduce(0, +)
        return InputTelemetry(eventsPerSecond: events, sendsPerSecond: sendsHz, totalSent: counts.sends, pads: pads)
    }
}

@MainActor
package final class TelemetrySource: StateSource<InputTelemetry> {

    private var counts: () -> InputCounts = { InputCounts() }
    private var clockUs: () -> UInt64 = uptimeUs
    private var rates = TelemetryRates()
    private var viewers = 0
    private var timer: DispatchSourceTimer?

    package init() {
        super.init(initial: InputTelemetry())
    }

    /// The counters to read and the clock to read them by, set once the owner has both.
    func use(counts: @escaping () -> InputCounts, clockUs: @escaping () -> UInt64) {
        self.counts = counts
        self.clockUs = clockUs
    }

    var isTicking: Bool {
        timer != nil
    }

    /// A page that shows the figures came on screen.
    func show() {
        viewers += 1
        refresh()
        arm()
    }

    /// A page that shows them left; the tick stops with the last.
    func hide() {
        viewers = max(viewers - 1, 0)
        guard viewers == 0 else { return }
        timer?.cancel()
        timer = nil
    }

    func refresh() {
        setState(rates.sample(counts(), nowUs: clockUs()))
    }

    private func arm() {
        guard timer == nil else { return }
        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(deadline: .now() + .seconds(1), repeating: .seconds(1))
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.refresh() }
        }
        source.resume()
        timer = source
    }
}

/// The uptime clock in microseconds.
func uptimeUs() -> UInt64 {
    DispatchTime.now().uptimeNanoseconds / 1000
}
