// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// The per-stream rate estimator behind the inspector's live figure.
// Quantized to 5 Hz steps so a jittery counter does not flicker the readout
// every poll. There is no clock inside: the caller passes the sample instant
// in microseconds on any monotonic basis, per the hot-path rule that timing
// never comes from a hidden now().

import Foundation

/// Rounds half away from zero, so 22.5 quantizes to 25 deterministically.
public func quantizeHz(_ hz: Double, step: Int = 5) -> Int {
    guard hz > 0 else { return 0 }
    guard step > 1 else { return Int(hz.rounded()) }
    let stepsAway = (hz / Double(step)).rounded()
    return Int(stepsAway) * step
}

public struct InputRateTracker: Equatable, Sendable {
    private var hasBaseline = false
    private var lastCount: UInt64 = 0
    private var lastUs: UInt64 = 0
    public private(set) var lastHz = 0

    public init() {}

    /// `count` is the absolute counter value at `nowUs`. The first sample
    /// anchors and reads zero; a counter that went backwards (the device
    /// re-attached) rebaselines rather than reporting a wrap's huge rate; a
    /// clock that did not advance holds the last reading and re-anchors the
    /// count so the next real interval is measured from here.
    public mutating func sample(count: UInt64, nowUs: UInt64) -> Int {
        guard hasBaseline else {
            hasBaseline = true
            lastCount = count
            lastUs = nowUs
            lastHz = 0
            return 0
        }
        guard count >= lastCount else {
            lastCount = count
            lastUs = nowUs
            lastHz = 0
            return 0
        }
        guard nowUs > lastUs else {
            lastCount = count
            return lastHz
        }
        let hz = Double(count - lastCount) * 1_000_000 / Double(nowUs - lastUs)
        lastCount = count
        lastUs = nowUs
        lastHz = quantizeHz(hz)
        return lastHz
    }

    /// A device detached; a new one may reuse the slot id.
    public mutating func reset() {
        self = InputRateTracker()
    }
}
