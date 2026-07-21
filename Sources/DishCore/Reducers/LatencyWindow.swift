// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// LatencyWindow — the pure sliding-window RTT estimator behind the
// per-connection one-way latency readout. Heartbeat RTT samples (ping sent →
// ack received, ms) slide through a fixed 64-sample window; the displayed
// one-way latency is the window median halved (symmetric-path estimate), so
// the figure answers "now", not "since the session opened". Ports dish-linux
// Util/LatencyWindow.h (which mirrors dish-android hotpath_latency.cpp
// kRttWindow=64, shouldArmPing's in-flight guard + loss reclaim, and the
// validity clamp).
//
// Pure value type, no clock inside — the imperative shell stamps instants
// from its own monotonic millisecond clock and passes them in.

import Foundation

/// Sliding heartbeat-RTT window + the single-in-flight ping clock.
/// One instance per session, guarded by the owner's lock — the type itself
/// is single-threaded.
public struct LatencyWindow: Equatable, Sendable {

    /// Window capacity: 64 samples ≈ 2 min at the 2 s heartbeat cadence, so
    /// the median tracks current network conditions (android kRttWindow).
    public static let capacity = ProtocolConstants.latencyWindowCapacity

    /// A ping unanswered past this is lost, not in flight (android kRttMaxNs
    /// = 5 s): past it the ping clock is reclaimed, and an RTT at/over it is
    /// dropped rather than skewing the window with a retransmit-scale outlier.
    public static let rttMaxMs = 5000.0

    private var samples: [Double]
    private var head = 0
    /// RTT samples currently in the window (0...capacity). The UI shows the
    /// figure only when this is > 0, so a fresh session reads blank rather
    /// than "~0.0 ms".
    public private(set) var sampleCount = 0
    /// Monotonic stamp (ms) of the heartbeat ping currently in flight;
    /// 0 = none. Callers use a positive monotonic clock.
    private var pingSentMs: Int64 = 0

    public init() {
        samples = [Double](repeating: 0, count: Self.capacity)
    }

    /// Record one RTT sample (milliseconds). Samples outside [0, rttMaxMs)
    /// are dropped — a negative delta (clock retrograde) or a lost-then-
    /// answered ping must not skew the median (android addRttSample's
    /// validity clamp). NaN fails the >= 0 comparison and is dropped by the
    /// same branch.
    public mutating func recordRtt(ms: Double) {
        guard ms >= 0.0, ms < Self.rttMaxMs else { return }
        samples[head] = ms
        head = (head + 1) % Self.capacity
        if sampleCount < Self.capacity {
            sampleCount += 1
        }
    }

    /// Median RTT over the window, halved (the one-way symmetric-path
    /// estimate). Nil while the window is empty — callers render a blank
    /// readout. Median = the same nearest-rank quantile android's statsJson
    /// uses (index round(0.5 × (n − 1)) of the sorted window; upper-middle
    /// for even n), so the clients render identical figures from identical
    /// samples.
    public func p50OneWayMs() -> Double? {
        guard sampleCount > 0 else { return nil }
        let sorted = samples[0 ..< sampleCount].sorted()
        let index = Int((0.5 * Double(sampleCount - 1)).rounded())
        return sorted[index] / 2.0
    }

    /// Whether the heartbeat sender may stamp a fresh ping clock. Keep an
    /// in-flight ping's clock: overwriting would pair its late ack with a
    /// newer ping's stamp and read artificially low. Past the validity window
    /// the ping is lost; reclaim. Mirrors android hotpath::shouldArmPing.
    public func shouldArmPing(nowMs: Int64) -> Bool {
        pingSentMs == 0 || nowMs - pingSentMs >= Int64(Self.rttMaxMs)
    }

    /// Stamp the ping clock IF the arming rule allows it (single-in-flight +
    /// 5 s loss reclaim baked in — callers just call this on every heartbeat
    /// send). `nowMs` is a positive monotonic stamp.
    public mutating func armPing(nowMs: Int64) {
        guard shouldArmPing(nowMs: nowMs) else { return }
        pingSentMs = nowMs
    }

    /// Pair an arriving ack with the in-flight ping: consume the clock (so a
    /// duplicate ack can't double-count) and slide the RTT into the window.
    /// `recordRtt` itself drops a sample past the loss cap — a reclaimed
    /// ping's stale ack never skews the median. No-op when no ping is
    /// outstanding.
    public mutating func ackReceived(nowMs: Int64) {
        guard pingSentMs != 0 else { return }
        let rtt = Double(nowMs - pingSentMs)
        pingSentMs = 0
        recordRtt(ms: rtt)
    }

    /// Drop every sample and the ping clock (a new session's window starts
    /// fresh — the readout answers THIS session).
    public mutating func reset() {
        head = 0
        sampleCount = 0
        pingSentMs = 0
    }
}

/// "~3.4 ms" — the displayed one-way figure, rounded to one decimal (half
/// away from zero, never banker's) and clamped at 0. Built digit-wise so the
/// decimal separator is '.' regardless of the process locale; the UI layer
/// appends its own localized sample-count suffix.
public func formatLatencyMs(_ oneWayMs: Double) -> String {
    guard oneWayMs.isFinite, oneWayMs > 0.0 else { return "~0.0 ms" }
    let tenths = Int((oneWayMs * 10.0).rounded())
    return "~\(tenths / 10).\(tenths % 10) ms"
}
