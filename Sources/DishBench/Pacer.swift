// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import DishEngine
import Foundation

/// The bench's clock, the one the loopback satellite stamps arrivals with.
func benchNow() -> UInt64 {
    clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
}

func microseconds(_ ns: UInt64) -> Double {
    Double(ns) / 1000
}

/// Stamps a stream writes frame by frame, one thread at a time, and the bench
/// reads once the stream has stopped.
final class StampLog: @unchecked Sendable {
    let capacity: Int
    private let stamps: UnsafeMutablePointer<UInt64>

    init(capacity: Int) {
        self.capacity = capacity
        stamps = .allocate(capacity: max(capacity, 1))
        stamps.initialize(repeating: 0, count: max(capacity, 1))
    }

    deinit {
        stamps.deallocate()
    }

    func record(_ frame: Int, _ ns: UInt64) {
        guard frame < capacity else { return }
        stamps[frame] = ns
    }

    var values: [UInt64] {
        Array(UnsafeBufferPointer(start: stamps, count: capacity))
    }
}

/// One stream fed to absolute deadlines on a thread of its own: a sleep to
/// within the spin window of each deadline, then a spin to it.
struct Pacer {
    let schedule: PaceSchedule
    let frames: Int
    let spinNs: UInt64
    let role: ThreadRole?
    let issued: StampLog

    func start(emit: @escaping @Sendable (Int) -> Void, finish: @escaping @Sendable () -> Void) {
        let schedule = schedule
        let frames = frames
        let spinNs = spinNs
        let role = role
        let issued = issued
        let thread = Thread {
            role?.enterThread()
            for frame in 0 ..< frames {
                waitUntil(schedule.deadline(UInt64(frame)), spinNs: spinNs)
                issued.record(frame, benchNow())
                emit(frame)
            }
            finish()
        }
        thread.qualityOfService = .userInteractive
        thread.start()
    }
}

func waitUntil(_ deadlineNs: UInt64, spinNs: UInt64) {
    if let sleepNs = sleepBeforeSpin(nowNs: benchNow(), deadlineNs: deadlineNs, spinNs: spinNs) {
        Thread.sleep(forTimeInterval: Double(sleepNs) / Double(PaceSchedule.nsPerSecond))
    }
    while benchNow() < deadlineNs {}
}

/// How the spin window is chosen: a millisecond, or more where this
/// machine's sleeps wake later, so a coarse timer cannot make a stream late.
enum SpinCalibration {
    static let samples = 30
    static let probeNs: UInt64 = 2_000_000
    static let floorNs: UInt64 = 1_000_000
    static let marginNs: UInt64 = 250_000
    static let ceilingNs: UInt64 = 8_000_000

    /// The 90th percentile of how late a 2 ms sleep wakes, plus a margin,
    /// within the floor and the ceiling.
    static func window(overshootsNs: [UInt64]) -> UInt64 {
        let late = nearestRankPercentile(overshootsNs.sorted(), 0.9) ?? 0
        return min(max(floorNs, late + marginNs), ceilingNs)
    }

    /// Measures this thread's sleeps; run on a thread of the pacers' quality.
    static func measure() -> UInt64 {
        var overshoots: [UInt64] = []
        for _ in 0 ..< samples {
            let before = benchNow()
            Thread.sleep(forTimeInterval: Double(probeNs) / Double(PaceSchedule.nsPerSecond))
            let slept = benchNow() - before
            overshoots.append(slept > probeNs ? slept - probeNs : 0)
        }
        return window(overshootsNs: overshoots)
    }
}
