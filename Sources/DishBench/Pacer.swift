// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Darwin
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
    /// Whether the pacer's thread ran under a time constraint; set before its first frame.
    var timeConstrained = false
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

/// One stream fed to absolute deadlines on a thread of its own: a timed wait
/// to within the spin window of each deadline, then a spin to it. A pacer
/// that only hands frames on runs under a time constraint, so the kernel
/// wakes it on time without the timer slack a sleeping thread gets.
struct Pacer {
    let schedule: PaceSchedule
    let frames: Int
    let spinNs: UInt64
    let role: ThreadRole?
    let timeConstrained: Bool
    let issued: StampLog

    func start(emit: @escaping @Sendable (Int) -> Void, finish: @escaping @Sendable () -> Void) {
        let schedule = schedule
        let frames = frames
        let spinNs = spinNs
        let role = role
        let constrained = timeConstrained
        let issued = issued
        let thread = Thread {
            role?.enterThread()
            if constrained {
                issued.timeConstrained = enterTimeConstraint(periodNs: PaceSchedule.nsPerSecond / schedule.rateHz)
            }
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
    if sleepBeforeSpin(nowNs: benchNow(), deadlineNs: deadlineNs, spinNs: spinNs) != nil {
        // An interrupted wait only leaves more to spin.
        _ = mach_wait_until(machTicks(deadlineNs - spinNs))
    }
    while benchNow() < deadlineNs {}
}

/// The bench clock's nanoseconds as mach absolute time, the unit
/// `mach_wait_until` and the time-constraint policy take.
func machTicks(_ ns: UInt64) -> UInt64 {
    ns * machTimebase.denom / machTimebase.numer
}

private let machTimebase: (numer: UInt64, denom: UInt64) = {
    var info = mach_timebase_info_data_t()
    guard mach_timebase_info(&info) == KERN_SUCCESS, info.numer > 0, info.denom > 0 else { return (1, 1) }
    return (UInt64(info.numer), UInt64(info.denom))
}()

/// Puts the calling thread under a time constraint for a stream of `periodNs`:
/// half the period, at most half a millisecond, to compute in each, done
/// within the period. False where the kernel refuses it.
func enterTimeConstraint(periodNs: UInt64) -> Bool {
    let computationNs = min(periodNs / 2, SpinCalibration.computationCapNs)
    var policy = thread_time_constraint_policy_data_t(
        period: UInt32(clamping: machTicks(periodNs)),
        computation: UInt32(clamping: machTicks(computationNs)),
        constraint: UInt32(clamping: machTicks(periodNs)),
        preemptible: 1
    )
    let count = mach_msg_type_number_t(MemoryLayout<thread_time_constraint_policy_data_t>.size / MemoryLayout<integer_t>.size)
    let status = withUnsafeMutablePointer(to: &policy) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { fields in
            thread_policy_set(pthread_mach_thread_np(pthread_self()), thread_policy_flavor_t(THREAD_TIME_CONSTRAINT_POLICY), fields, count)
        }
    }
    return status == KERN_SUCCESS
}

/// How late a time-constrained thread's timed waits wake on this machine,
/// and the spin window that follows from it.
struct TimerCalibration: Equatable {
    let timeConstrained: Bool
    let lateP90Ns: UInt64
    let spinNs: UInt64
}

/// The spin window is the 90th percentile of how late a 2 ms wait wakes,
/// plus a margin, within a floor and a millisecond: a spinning thread under a
/// time constraint must stay inside its computation, and on a small runner
/// every spinning thread takes a core from the path under test.
enum SpinCalibration {
    static let samples = 30
    static let probeNs: UInt64 = 2_000_000
    static let floorNs: UInt64 = 100_000
    static let marginNs: UInt64 = 100_000
    static let ceilingNs: UInt64 = 1_000_000
    static let computationCapNs: UInt64 = 500_000
    /// The Direct pad's thread is the reader's own and runs unconstrained,
    /// as the reader does, so it spins the whole millisecond before each report.
    static let directSpinNs: UInt64 = 1_000_000

    static func window(lateP90Ns: UInt64) -> UInt64 {
        min(max(floorNs, lateP90Ns + marginNs), ceilingNs)
    }

    /// Times 30 waits of 2 ms on a time-constrained thread of its own.
    static func measure() -> TimerCalibration {
        let done = DispatchSemaphore(value: 0)
        let probe = StampLog(capacity: samples)
        let thread = Thread {
            probe.timeConstrained = enterTimeConstraint(periodNs: probeNs)
            for sample in 0 ..< samples {
                let before = benchNow()
                // The wait is judged by how late it woke, whatever it returns.
                _ = mach_wait_until(machTicks(before + probeNs))
                let waited = benchNow() - before
                probe.record(sample, waited > probeNs ? waited - probeNs : 0)
            }
            done.signal()
        }
        thread.qualityOfService = .userInteractive
        thread.start()
        done.wait()
        let late = nearestRankPercentile(probe.values.sorted(), 0.9) ?? 0
        return TimerCalibration(timeConstrained: probe.timeConstrained, lateP90Ns: late, spinNs: window(lateP90Ns: late))
    }
}
