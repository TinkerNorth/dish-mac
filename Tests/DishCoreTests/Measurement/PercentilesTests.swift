// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import XCTest

/// The bench's figures: nearest-rank percentiles of the samples, the rep
/// whose figure is the median, and the lock statistics' power-of-two
/// histograms.
final class PercentilesTests: XCTestCase {

    private let thousand = (1 ... 1000).map { UInt64($0) }

    func testTheNearestRankIsTheSmallestSampleWithTheFractionAtOrBelowIt() {
        XCTAssertEqual(nearestRankPercentile(thousand, 0.5), 500)
        XCTAssertEqual(nearestRankPercentile(thousand, 0.99), 990)
        XCTAssertEqual(nearestRankPercentile(thousand, 0.999), 999)
        XCTAssertEqual(nearestRankPercentile(thousand, 1), 1000)
        XCTAssertEqual(nearestRankPercentile([10, 20], 0.5), 10)
    }

    func testOneSampleIsEveryPercentileAndNoSampleIsNone() {
        XCTAssertEqual(nearestRankPercentile([7], 0), 7)
        XCTAssertEqual(nearestRankPercentile([7], 0.999), 7)
        XCTAssertNil(nearestRankPercentile([], 0.5))
    }

    func testTheMedianRepIsTheLowerMiddleWithTiesToTheEarlierOne() {
        XCTAssertEqual(medianIndex([3, 1, 2]), 2)
        XCTAssertEqual(medianIndex([5, 1, 3, 2]), 3, "values 1, 2, 3, 5: the lower middle is 2, at index 3")
        XCTAssertEqual(medianIndex([2, 2, 2]), 1)
        XCTAssertNil(medianIndex([]))
    }

    func testAValueLandsInTheBucketOfItsBitWidth() {
        XCTAssertEqual(Log2Histogram.bucket(0), 0)
        XCTAssertEqual(Log2Histogram.bucket(1), 1)
        XCTAssertEqual(Log2Histogram.bucket(2), 2)
        XCTAssertEqual(Log2Histogram.bucket(3), 2)
        XCTAssertEqual(Log2Histogram.bucket(4), 3)
        XCTAssertEqual(Log2Histogram.bucket(.max), Log2Histogram.buckets - 1, "anything wider shares the last bucket")
    }

    func testABucketsUpperBoundIsTheLargestValueItHolds() {
        XCTAssertEqual(Log2Histogram.upperBound(0), 0)
        XCTAssertEqual(Log2Histogram.upperBound(1), 1)
        XCTAssertEqual(Log2Histogram.upperBound(2), 3)
        XCTAssertEqual(Log2Histogram.upperBound(10), 1023)
        XCTAssertEqual(Log2Histogram.upperBound(64), .max)
    }

    func testAHistogramPercentileIsTheUpperBoundOfTheBucketTheRankReaches() {
        var histogram = [UInt64](repeating: 0, count: Log2Histogram.buckets)
        histogram[3] = 99
        histogram[10] = 1
        XCTAssertEqual(Log2Histogram.percentile(histogram, 0.5), 7)
        XCTAssertEqual(Log2Histogram.percentile(histogram, 0.99), 7)
        XCTAssertEqual(Log2Histogram.percentile(histogram, 0.999), 1023)
        XCTAssertEqual(Log2Histogram.percentile([UInt64](repeating: 0, count: 4), 0.99), 0, "an empty histogram reads 0")
    }
}
