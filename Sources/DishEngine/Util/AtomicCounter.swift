// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Foundation

/// A counter several threads advance and read without a lock: the replay
/// guard the receive loop moves, the sends the telemetry counts. Every
/// operation is one atomic instruction on the word.
final class AtomicCounter: @unchecked Sendable {
    private let word = AtomicWord.allocate()

    deinit {
        word.deallocate()
    }

    /// Returns the post-increment value.
    func incrementAndGet() -> UInt64 {
        UInt64(bitPattern: word.fetchAdd(1)) &+ 1
    }

    /// Advance by one where nothing reads the new value: a tally.
    func increment() {
        word.fetchAddRelaxed(1)
    }

    /// Current value without advancing.
    func current() -> UInt64 {
        UInt64(bitPattern: word.load())
    }

    /// Force a specific value. Production code only ever `reset()`s; tests
    /// use this to place the counter near the exhaustion threshold without
    /// four billion increments.
    func set(_ newValue: UInt64) {
        word.store(Int64(bitPattern: newValue))
    }

    func reset() {
        word.store(0)
    }
}

/// An `Int` written on one thread and read or reset on another without a
/// lock: the heartbeat's `missedAcks`, which the heartbeat bumps and the
/// receive loop zeroes; the close latch; the keep-awake clock.
final class AtomicInt: @unchecked Sendable {
    private let word: AtomicWord

    init(_ initial: Int = 0) {
        word = AtomicWord.allocate(Int64(initial))
    }

    deinit {
        word.deallocate()
    }

    /// Returns the post-increment value.
    func incrementAndGet() -> Int {
        Int(word.fetchAdd(1)) + 1
    }

    func set(_ newValue: Int) {
        word.store(Int64(newValue))
    }

    func get() -> Int {
        Int(word.load())
    }
}

/// A `Bool` several threads read and write without a lock: the loops' run
/// flags and the session's liveness, which the heartbeat and the receive
/// loop write and the alive tick reads.
final class AtomicBool: @unchecked Sendable {
    private let word: AtomicWord

    init(_ initial: Bool) {
        word = AtomicWord.allocate(initial ? 1 : 0)
    }

    deinit {
        word.deallocate()
    }

    /// Stores `newValue` and returns what was there, as one step.
    func getAndSet(_ newValue: Bool) -> Bool {
        word.exchange(newValue ? 1 : 0) != 0
    }

    func set(_ newValue: Bool) {
        word.store(newValue ? 1 : 0)
    }

    func get() -> Bool {
        word.load() != 0
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
