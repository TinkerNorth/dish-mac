// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Foundation

/// The nearest-rank percentile of `sorted`, which is ascending: the smallest
/// sample with at least `fraction` of the samples at or below it. Nil for no
/// samples.
public func nearestRankPercentile(_ sorted: [UInt64], _ fraction: Double) -> UInt64? {
    guard !sorted.isEmpty else { return nil }
    let rank = Int(rankFor(fraction, of: sorted.count))
    let clamped = min(max(rank, 1), sorted.count)
    return sorted[clamped - 1]
}

/// The rank a fraction of `count` samples reaches, rounded up; the nudge
/// keeps 0.999 of 1000 at 999 when the product lands a rounding error above.
private func rankFor(_ fraction: Double, of count: Int) -> Double {
    let exact = fraction * Double(count)
    return max((exact - 1e-9).rounded(.up), 0)
}

/// The index of the median of `figures`, the lower middle of an even count,
/// ties going to the earlier index; nil for no figures.
public func medianIndex(_ figures: [Double]) -> Int? {
    guard !figures.isEmpty else { return nil }
    let order = figures.indices.sorted { (figures[$0], $0) < (figures[$1], $1) }
    return order[(order.count - 1) / 2]
}

/// Nanosecond figures counted by power of two: bucket `b` holds the values
/// `b` bits wide (0, 1, 2 to 3, 4 to 7, ...), the last bucket everything
/// wider.
public enum Log2Histogram {
    public static let buckets = 40

    public static func bucket(_ value: UInt64) -> Int {
        let width = UInt64.bitWidth - value.leadingZeroBitCount
        return min(width, buckets - 1)
    }

    /// The largest value bucket `index` holds.
    public static func upperBound(_ index: Int) -> UInt64 {
        guard index > 0 else { return 0 }
        guard index < UInt64.bitWidth else { return .max }
        return (UInt64(1) << UInt64(index)) - 1
    }

    /// The upper bound of the bucket the nearest-rank percentile lands in;
    /// 0 for an empty histogram.
    public static func percentile(_ histogram: [UInt64], _ fraction: Double) -> UInt64 {
        let total = histogram.reduce(0, +)
        guard total > 0 else { return 0 }
        let rank = max(UInt64(rankFor(fraction, of: Int(total))), 1)
        var seen: UInt64 = 0
        for (index, count) in histogram.enumerated() {
            seen += count
            if seen >= rank { return upperBound(index) }
        }
        return upperBound(histogram.count - 1)
    }
}
