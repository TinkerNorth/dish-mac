// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Foundation

/// Tiny lock-protected counter. Used as the ChaCha20 nonce sequence for every
/// session — every `sendReport` on the hot path takes this lock once. The
/// spinlock-free lock acquisition on uncontended `os_unfair_lock` is on the
/// order of nanoseconds, so this stays well under the one-report budget.
final class AtomicCounter: @unchecked Sendable {
    private var value: UInt64 = 0
    private var lock: TrackedLock<os_unfair_lock_s>

    init(name: StaticString = "util.atomicCounter") {
        lock = TrackedLock(os_unfair_lock_s(), name)
    }

    /// Returns the post-increment value.
    func incrementAndGet() -> UInt64 {
        lock.lock()
        value &+= 1
        let current = value
        lock.unlock()
        return current
    }

    /// Advance by one where nothing reads the new value: a tally.
    func increment() {
        lock.lock()
        value &+= 1
        lock.unlock()
    }

    /// Current value without advancing — the rekey poll (`needsRekey`)
    /// compares this against the contract's re-PUT threshold.
    func current() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    /// Force a specific value. Production code only ever `reset()`s; tests
    /// use this to place the counter near the exhaustion threshold without
    /// four billion increments.
    func set(_ newValue: UInt64) {
        lock.lock()
        value = newValue
        lock.unlock()
    }

    func reset() {
        lock.lock()
        value = 0
        lock.unlock()
    }
}

/// Lock-guarded `Int`, for counters that are incremented on one queue and
/// reset on another — e.g. the heartbeat's `missedAcks`, which the heartbeat
/// loop bumps and the ACK receive loop zeroes. A plain `var` racing across
/// two `DispatchQueue`s is undefined behaviour; this serialises every access.
final class AtomicInt: @unchecked Sendable {
    private var value: Int
    private var lock: TrackedLock<os_unfair_lock_s>

    init(_ initial: Int = 0, name: StaticString = "util.atomicInt") {
        value = initial
        lock = TrackedLock(os_unfair_lock_s(), name)
    }

    /// Returns the post-increment value.
    func incrementAndGet() -> Int {
        lock.lock()
        value += 1
        let current = value
        lock.unlock()
        return current
    }

    func set(_ newValue: Int) {
        lock.lock()
        value = newValue
        lock.unlock()
    }

    func get() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// Lock-guarded `Bool`. Same rationale as `AtomicInt`: the heartbeat's
/// `connectionAlive` flag is written from the heartbeat + ACK queues and read
/// from the `WifiConnection` liveness task — three threads, one flag.
final class AtomicBool: @unchecked Sendable {
    private var value: Bool
    private var lock: TrackedLock<os_unfair_lock_s>

    init(_ initial: Bool, name: StaticString = "util.atomicBool") {
        value = initial
        lock = TrackedLock(os_unfair_lock_s(), name)
    }

    /// Stores `newValue` and returns what was there, as one step.
    func getAndSet(_ newValue: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let previous = value
        value = newValue
        return previous
    }

    func set(_ newValue: Bool) {
        lock.lock()
        value = newValue
        lock.unlock()
    }

    func get() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// Lock-guarded box for any value crossing threads whole — session crypto
/// params swapped by a re-key while the send/receive paths read them, the
/// return-path handlers installed from the main actor and invoked on the
/// receive queue, the enriched-ack snapshot. Same `os_unfair_lock` bridge
/// family as the atomics above (PLAN D6: no actor rewrite this initiative).
final class LockedBox<Value>: @unchecked Sendable {
    private var value: Value
    private var lock: TrackedLock<os_unfair_lock_s>

    init(_ initial: Value, name: StaticString = "util.lockedBox") {
        value = initial
        lock = TrackedLock(os_unfair_lock_s(), name)
    }

    func get() -> Value {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ newValue: Value) {
        lock.lock()
        value = newValue
        lock.unlock()
    }

    /// Read-modify-write under one lock hold, returning `body`'s result —
    /// for values whose fields must never be observed across two holds
    /// (the session params' key/token/counter draw).
    func mutate<T>(_ body: (inout Value) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}
