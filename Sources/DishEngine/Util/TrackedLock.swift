// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Foundation

/// The primitive under a `TrackedLock`: the unfair lock or the `NSLock` the
/// call site took before the lock had a name.
protocol LockPrimitive {
    mutating func lock()
    mutating func unlock()
    mutating func lockIfFree() -> Bool
}

extension os_unfair_lock_s: LockPrimitive {
    mutating func lock() {
        os_unfair_lock_lock(&self)
    }

    mutating func unlock() {
        os_unfair_lock_unlock(&self)
    }

    mutating func lockIfFree() -> Bool {
        os_unfair_lock_trylock(&self)
    }
}

extension NSLock: LockPrimitive {
    func lockIfFree() -> Bool {
        self.try()
    }
}

/// A lock with a stable name, `area.thing`. The plain build holds the
/// primitive and nothing else; a LOCK_STATS build also counts, per thread
/// role, each acquisition, its wait and hold, the locks it nests inside and
/// the blocking calls made while it is held.
struct TrackedLock<Primitive: LockPrimitive> {
    private var primitive: Primitive
    #if LOCK_STATS
    private let id: Int
    #endif

    init(_ primitive: Primitive, _ name: StaticString) {
        self.primitive = primitive
        #if LOCK_STATS
        id = lockStatsLockId(name)
        #endif
    }

    #if LOCK_STATS
    mutating func lock() {
        let thread = LockThreadState.current()
        let role = thread.noteAttempt(id)
        let requestedNs = lockStatsNow()
        let contended = !primitive.lockIfFree()
        if contended { primitive.lock() }
        thread.noteAcquired(id, role: role, requestedNs: requestedNs, contended: contended)
    }

    mutating func unlock() {
        let thread = LockThreadState.current()
        let release = thread.takeHeld(id)
        primitive.unlock()
        thread.record(release)
    }
    #else
    mutating func lock() {
        primitive.lock()
    }

    mutating func unlock() {
        primitive.unlock()
    }
    #endif
}
