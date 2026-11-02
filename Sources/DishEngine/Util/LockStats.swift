// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

#if LOCK_STATS
import DishCore
import Foundation

/// One lock's counts on one thread role.
package struct LockRoleCounters: Equatable {
    package var acquisitions: UInt64 = 0
    package var contended: UInt64 = 0
    package var waitTotalNs: UInt64 = 0
    package var waitMaxNs: UInt64 = 0
    package var holdTotalNs: UInt64 = 0
    package var holdMaxNs: UInt64 = 0
    package var waitHistogram = [UInt64](repeating: 0, count: Log2Histogram.buckets)
    package var holdHistogram = [UInt64](repeating: 0, count: Log2Histogram.buckets)

    package init() {}

    package var waitP99Ns: UInt64 {
        Log2Histogram.percentile(waitHistogram, 0.99)
    }

    package var holdP99Ns: UInt64 {
        Log2Histogram.percentile(holdHistogram, 0.99)
    }

    mutating func add(_ release: LockThreadState.Release) {
        acquisitions += 1
        if release.contended { contended += 1 }
        waitTotalNs &+= release.waitNs
        waitMaxNs = max(waitMaxNs, release.waitNs)
        holdTotalNs &+= release.holdNs
        holdMaxNs = max(holdMaxNs, release.holdNs)
        waitHistogram[Log2Histogram.bucket(release.waitNs)] += 1
        holdHistogram[Log2Histogram.bucket(release.holdNs)] += 1
    }

    mutating func merge(_ other: LockRoleCounters) {
        acquisitions += other.acquisitions
        contended += other.contended
        waitTotalNs &+= other.waitTotalNs
        waitMaxNs = max(waitMaxNs, other.waitMaxNs)
        holdTotalNs &+= other.holdTotalNs
        holdMaxNs = max(holdMaxNs, other.holdMaxNs)
        for index in waitHistogram.indices {
            waitHistogram[index] += other.waitHistogram[index]
            holdHistogram[index] += other.holdHistogram[index]
        }
    }
}

/// Two names in order: an outer lock and a lock taken inside it, or a
/// blocking region and a lock held across it.
package struct LockPair: Hashable, Comparable {
    package let first: String
    package let second: String

    package init(_ first: String, _ second: String) {
        self.first = first
        self.second = second
    }

    package static func < (lhs: LockPair, rhs: LockPair) -> Bool {
        (lhs.first, lhs.second) < (rhs.first, rhs.second)
    }
}

/// Every tracked lock's counts since the last reset, merged across threads.
package struct LockStatsSnapshot: Equatable {
    package var locks: [String: [ThreadRole: LockRoleCounters]] = [:]
    package var edges: [LockPair: UInt64] = [:]
    package var blocking: [LockPair: UInt64] = [:]
    package var regions: [String: UInt64] = [:]

    package init() {}

    /// The locks `role` acquired at least once.
    package func acquired(by role: ThreadRole) -> Set<String> {
        Set(locks.filter { ($0.value[role]?.acquisitions ?? 0) > 0 }.keys)
    }

    package func counters(_ lock: String, _ role: ThreadRole) -> LockRoleCounters {
        locks[lock]?[role] ?? LockRoleCounters()
    }
}

package func lockStatsSnapshot() -> LockStatsSnapshot {
    lockStatsRegistry.snapshot()
}

package func resetLockStats() {
    lockStatsRegistry.reset()
}

let threadRoleKey = DispatchSpecificKey<ThreadRole>()

func lockStatsNow() -> UInt64 {
    clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
}

func lockStatsLockId(_ name: StaticString) -> Int {
    lockStatsRegistry.lockId(name.description)
}

func lockStatsRegionId(_ name: StaticString) -> Int {
    lockStatsRegistry.regionId(name.description)
}

/// The statistics build counts every lock wherever it is made, so its
/// registry is one per process; the plain build has none.
private let lockStatsRegistry = LockStatsRegistry()

private let lockThreadStateKey: pthread_key_t = {
    var key = pthread_key_t()
    let created = pthread_key_create(&key, nil)
    precondition(created == 0, "LOCK_STATS needs a thread-specific key")
    return key
}()

private func pairKey(_ first: Int, _ second: Int) -> Int {
    first << 16 | second
}

/// The names and every thread's counts. Its own lock and each thread's are
/// leaves: nothing is acquired while either is held.
final class LockStatsRegistry: @unchecked Sendable {
    private var guardLock = os_unfair_lock_s()
    private var lockNames: [String] = []
    private var lockIds: [String: Int] = [:]
    private var regionNames: [String] = []
    private var regionIds: [String: Int] = [:]
    private var threads: [LockThreadState] = []

    func lockId(_ name: String) -> Int {
        os_unfair_lock_lock(&guardLock)
        defer { os_unfair_lock_unlock(&guardLock) }
        return Self.intern(name, names: &lockNames, ids: &lockIds)
    }

    func regionId(_ name: String) -> Int {
        os_unfair_lock_lock(&guardLock)
        defer { os_unfair_lock_unlock(&guardLock) }
        return Self.intern(name, names: &regionNames, ids: &regionIds)
    }

    func register(_ thread: LockThreadState) {
        os_unfair_lock_lock(&guardLock)
        threads.append(thread)
        os_unfair_lock_unlock(&guardLock)
    }

    func snapshot() -> LockStatsSnapshot {
        os_unfair_lock_lock(&guardLock)
        let names = LockStatsNames(locks: lockNames, regions: regionNames)
        let everyThread = threads
        os_unfair_lock_unlock(&guardLock)
        var snapshot = LockStatsSnapshot()
        for thread in everyThread {
            thread.merge(into: &snapshot, names: names)
        }
        return snapshot
    }

    func reset() {
        os_unfair_lock_lock(&guardLock)
        let everyThread = threads
        os_unfair_lock_unlock(&guardLock)
        for thread in everyThread {
            thread.clear()
        }
    }

    private static func intern(_ name: String, names: inout [String], ids: inout [String: Int]) -> Int {
        if let known = ids[name] { return known }
        let id = names.count
        names.append(name)
        ids[name] = id
        return id
    }
}

/// The names behind the ids, as a snapshot reads them.
struct LockStatsNames {
    let locks: [String]
    let regions: [String]

    func lock(_ id: Int) -> String? {
        locks.indices.contains(id) ? locks[id] : nil
    }

    func region(_ id: Int) -> String? {
        regions.indices.contains(id) ? regions[id] : nil
    }
}

/// One thread's held locks and counts. The held stack is touched only by its
/// thread; the counts sit under a lock the snapshot shares.
final class LockThreadState: @unchecked Sendable {
    struct Held {
        let lock: Int
        let role: ThreadRole
        let waitNs: UInt64
        let contended: Bool
        let sinceNs: UInt64
    }

    struct Release {
        let lock: Int
        let role: ThreadRole
        let waitNs: UInt64
        let contended: Bool
        let holdNs: UInt64
    }

    private static let roleCount = ThreadRole.allCases.count

    var role: ThreadRole?
    private var held: [Held] = []
    private var countsLock = os_unfair_lock_s()
    private var counters: [Int: LockRoleCounters] = [:]
    private var edges: [Int: UInt64] = [:]
    private var blocking: [Int: UInt64] = [:]
    private var regionHits: [Int: UInt64] = [:]

    init() {
        held.reserveCapacity(16)
    }

    static func current() -> LockThreadState {
        if let raw = pthread_getspecific(lockThreadStateKey) {
            return Unmanaged<LockThreadState>.fromOpaque(raw).takeUnretainedValue()
        }
        let state = LockThreadState()
        lockStatsRegistry.register(state)
        let stored = pthread_setspecific(lockThreadStateKey, Unmanaged.passUnretained(state).toOpaque())
        precondition(stored == 0, "LOCK_STATS could not keep a thread's state")
        return state
    }

    /// The role this acquisition counts under, after counting an edge from
    /// every lock the thread already holds to `lock`.
    func noteAttempt(_ lock: Int) -> ThreadRole {
        let resolved = currentRole()
        guard !held.isEmpty else { return resolved }
        os_unfair_lock_lock(&countsLock)
        for outer in held {
            edges[pairKey(outer.lock, lock), default: 0] += 1
        }
        os_unfair_lock_unlock(&countsLock)
        return resolved
    }

    func noteAcquired(_ lock: Int, role: ThreadRole, requestedNs: UInt64, contended: Bool) {
        let acquiredNs = lockStatsNow()
        let waitNs = acquiredNs > requestedNs ? acquiredNs - requestedNs : 0
        held.append(Held(lock: lock, role: role, waitNs: waitNs, contended: contended, sinceNs: acquiredNs))
    }

    func takeHeld(_ lock: Int) -> Release? {
        let releasedNs = lockStatsNow()
        guard let index = held.lastIndex(where: { $0.lock == lock }) else { return nil }
        let entry = held.remove(at: index)
        let holdNs = releasedNs > entry.sinceNs ? releasedNs - entry.sinceNs : 0
        return Release(lock: entry.lock, role: entry.role, waitNs: entry.waitNs, contended: entry.contended, holdNs: holdNs)
    }

    func record(_ release: Release?) {
        guard let release else { return }
        let key = release.lock * Self.roleCount + release.role.rawValue
        os_unfair_lock_lock(&countsLock)
        counters[key, default: LockRoleCounters()].add(release)
        os_unfair_lock_unlock(&countsLock)
    }

    func noteBlocking(_ region: Int) {
        os_unfair_lock_lock(&countsLock)
        regionHits[region, default: 0] += 1
        for entry in held {
            blocking[pairKey(region, entry.lock), default: 0] += 1
        }
        os_unfair_lock_unlock(&countsLock)
    }

    func merge(into snapshot: inout LockStatsSnapshot, names: LockStatsNames) {
        os_unfair_lock_lock(&countsLock)
        defer { os_unfair_lock_unlock(&countsLock) }
        for (key, counts) in counters {
            guard let name = names.lock(key / Self.roleCount), let role = ThreadRole(rawValue: key % Self.roleCount) else { continue }
            snapshot.locks[name, default: [:]][role, default: LockRoleCounters()].merge(counts)
        }
        for (key, count) in edges {
            guard let outer = names.lock(key >> 16), let inner = names.lock(key & 0xFFFF) else { continue }
            snapshot.edges[LockPair(outer, inner), default: 0] += count
        }
        for (key, count) in blocking {
            guard let region = names.region(key >> 16), let lock = names.lock(key & 0xFFFF) else { continue }
            snapshot.blocking[LockPair(region, lock), default: 0] += count
        }
        for (key, count) in regionHits {
            guard let region = names.region(key) else { continue }
            snapshot.regions[region, default: 0] += count
        }
    }

    func clear() {
        os_unfair_lock_lock(&countsLock)
        counters = [:]
        edges = [:]
        blocking = [:]
        regionHits = [:]
        os_unfair_lock_unlock(&countsLock)
    }

    private func currentRole() -> ThreadRole {
        if let marked = DispatchQueue.getSpecific(key: threadRoleKey) { return marked }
        if let role { return role }
        return pthread_main_np() != 0 ? .main : .other
    }
}
#endif
