// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Foundation

/// Tiny lock-protected counter. Used as the ChaCha20 nonce sequence for every
/// session — every `sendReport` on the hot path takes this lock once. The
/// spinlock-free lock acquisition on uncontended `os_unfair_lock` is on the
/// order of nanoseconds, so this stays well under the one-report budget.
final class AtomicCounter: @unchecked Sendable {
    private var value: UInt64 = 0
    private var lock = os_unfair_lock_s()

    /// Returns the post-increment value.
    func incrementAndGet() -> UInt64 {
        os_unfair_lock_lock(&lock)
        value &+= 1
        let current = value
        os_unfair_lock_unlock(&lock)
        return current
    }

    /// Current value without advancing — the rekey poll (`needsRekey`)
    /// compares this against the contract's re-PUT threshold.
    func current() -> UInt64 {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return value
    }

    /// Force a specific value. Production code only ever `reset()`s; tests
    /// use this to place the counter near the exhaustion threshold without
    /// four billion increments.
    func set(_ newValue: UInt64) {
        os_unfair_lock_lock(&lock)
        value = newValue
        os_unfair_lock_unlock(&lock)
    }

    func reset() {
        os_unfair_lock_lock(&lock)
        value = 0
        os_unfair_lock_unlock(&lock)
    }
}

/// Lock-guarded `Int`, for counters that are incremented on one queue and
/// reset on another — e.g. the heartbeat's `missedAcks`, which the heartbeat
/// loop bumps and the ACK receive loop zeroes. A plain `var` racing across
/// two `DispatchQueue`s is undefined behaviour; this serialises every access.
final class AtomicInt: @unchecked Sendable {
    private var value: Int
    private var lock = os_unfair_lock_s()

    init(_ initial: Int = 0) {
        value = initial
    }

    /// Returns the post-increment value.
    func incrementAndGet() -> Int {
        os_unfair_lock_lock(&lock)
        value += 1
        let current = value
        os_unfair_lock_unlock(&lock)
        return current
    }

    func set(_ newValue: Int) {
        os_unfair_lock_lock(&lock)
        value = newValue
        os_unfair_lock_unlock(&lock)
    }

    func get() -> Int {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return value
    }
}

/// Lock-guarded `Bool`. Same rationale as `AtomicInt`: the heartbeat's
/// `connectionAlive` flag is written from the heartbeat + ACK queues and read
/// from the `WifiConnection` liveness task — three threads, one flag.
final class AtomicBool: @unchecked Sendable {
    private var value: Bool
    private var lock = os_unfair_lock_s()

    init(_ initial: Bool) {
        value = initial
    }

    func set(_ newValue: Bool) {
        os_unfair_lock_lock(&lock)
        value = newValue
        os_unfair_lock_unlock(&lock)
    }

    func get() -> Bool {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
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
    private var lock = os_unfair_lock_s()

    init(_ initial: Value) {
        value = initial
    }

    func get() -> Value {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return value
    }

    func set(_ newValue: Value) {
        os_unfair_lock_lock(&lock)
        value = newValue
        os_unfair_lock_unlock(&lock)
    }

    /// Read-modify-write under one lock hold, returning `body`'s result —
    /// for values whose fields must never be observed across two holds
    /// (the session params' key/token/counter draw).
    func mutate<T>(_ body: (inout Value) -> T) -> T {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return body(&value)
    }
}
