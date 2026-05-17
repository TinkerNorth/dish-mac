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
