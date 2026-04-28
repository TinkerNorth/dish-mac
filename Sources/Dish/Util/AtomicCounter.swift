// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Foundation

/// Tiny lock-protected counter. Used as the ChaCha20 nonce sequence for every
/// session — every `sendReport` on the hot path takes this lock once. The
/// spinlock-free lock acquisition on uncontended `os_unfair_lock` is on the
/// order of nanoseconds, so this stays well under the one-report budget.
final class AtomicCounter {
    private var value: UInt64 = 0
    private var lock = os_unfair_lock_s()

    /// Returns the post-increment value.
    func incrementAndGet() -> UInt64 {
        os_unfair_lock_lock(&lock)
        value &+= 1
        let v = value
        os_unfair_lock_unlock(&lock)
        return v
    }

    func reset() {
        os_unfair_lock_lock(&lock)
        value = 0
        os_unfair_lock_unlock(&lock)
    }
}
