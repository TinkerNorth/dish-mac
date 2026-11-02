// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Foundation

/// One frame of a stream as it arrived: the 16-bit sequence it carried and
/// when it arrived.
public struct StreamArrival: Equatable, Sendable {
    public let sequence: UInt16
    public let ns: UInt64

    public init(sequence: UInt16, ns: UInt64) {
        self.sequence = sequence
        self.ns = ns
    }
}

/// The frame index a 16-bit sequence names: the index with those low 16 bits
/// nearest `expected`, so a stream longer than 65,536 frames resolves as long
/// as no frame arrives 32,768 frames out of place.
public func unwrapSequence(_ sequence: UInt16, near expected: Int) -> Int {
    let offset = Int16(bitPattern: sequence &- UInt16(truncatingIfNeeded: expected))
    return expected + Int(offset)
}

/// A stream's latency figures: each arrival matched, through its sequence, to
/// the send stamp of the frame it carried; the sequence ring is unwrapped
/// against the frame the previous arrival resolved to.
public struct LatencySummary: Equatable, Sendable {
    public static let overLimitNs: UInt64 = 1_000_000

    public let frames: Int
    public let received: Int
    public let duplicates: Int
    public let p50Ns: UInt64
    public let p99Ns: UInt64
    public let p999Ns: UInt64
    public let maxNs: UInt64
    public let overLimit: Int
    public let longestGapNs: UInt64

    public init(sentNs: [UInt64], arrivals: [StreamArrival]) {
        let matched = MatchedArrivals(sentNs: sentNs, arrivals: arrivals)
        let sorted = matched.latencies.sorted()
        frames = sentNs.count
        received = sorted.count
        duplicates = matched.duplicates
        p50Ns = nearestRankPercentile(sorted, 0.5) ?? 0
        p99Ns = nearestRankPercentile(sorted, 0.99) ?? 0
        p999Ns = nearestRankPercentile(sorted, 0.999) ?? 0
        maxNs = sorted.last ?? 0
        overLimit = sorted.count - (sorted.firstIndex { $0 > Self.overLimitNs } ?? sorted.count)
        longestGapNs = matched.longestGapNs
    }

    /// Frames sent that never arrived.
    public var drops: Int {
        frames - received
    }
}

/// The arrivals resolved to frames: one latency per frame that arrived, the
/// repeats of a frame already seen, and the longest wait between arrivals.
private struct MatchedArrivals {
    private(set) var latencies: [UInt64] = []
    private(set) var duplicates = 0
    private(set) var longestGapNs: UInt64 = 0

    init(sentNs: [UInt64], arrivals: [StreamArrival]) {
        var seen = [Bool](repeating: false, count: sentNs.count)
        var expected = 0
        var previousNs: UInt64?
        latencies.reserveCapacity(arrivals.count)
        for arrival in arrivals {
            if let previousNs { longestGapNs = max(longestGapNs, arrival.ns &- previousNs) }
            previousNs = arrival.ns
            let index = unwrapSequence(arrival.sequence, near: expected)
            guard sentNs.indices.contains(index) else { continue }
            expected = index + 1
            if seen[index] {
                duplicates += 1
                continue
            }
            seen[index] = true
            latencies.append(arrival.ns > sentNs[index] ? arrival.ns - sentNs[index] : 0)
        }
    }
}
