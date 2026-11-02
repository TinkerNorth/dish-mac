// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishEngine
import Foundation

/// A rep's lock counts in a LOCK_STATS build; empty in the plain one.
struct RepLocks {
    var rows: [LockRow] = []
    var nesting: [PairRow] = []
    var blocking: [PairRow] = []
}

#if LOCK_STATS
let lockStatsBuild = true
#else
let lockStatsBuild = false
#endif

func resetLockCounts() {
    #if LOCK_STATS
    resetLockStats()
    #endif
}

func countedLocks() -> RepLocks {
    #if LOCK_STATS
    let snapshot = lockStatsSnapshot()
    return RepLocks(rows: lockRows(snapshot), nesting: pairRows(snapshot.edges), blocking: pairRows(snapshot.blocking))
    #else
    return RepLocks()
    #endif
}

#if LOCK_STATS
private func lockRows(_ snapshot: LockStatsSnapshot) -> [LockRow] {
    let rows = snapshot.locks.flatMap { lock, roles in
        roles.filter { $0.value.acquisitions > 0 }.map { role, counts in
            LockRow(
                lock: lock,
                role: role.name,
                acquisitions: counts.acquisitions,
                contended: counts.contended,
                waitMaxUs: microseconds(counts.waitMaxNs),
                waitP99Us: microseconds(counts.waitP99Ns),
                holdMaxUs: microseconds(counts.holdMaxNs),
                holdP99Us: microseconds(counts.holdP99Ns)
            )
        }
    }
    return rows.sorted { ($0.lock, $0.role) < ($1.lock, $1.role) }
}

private func pairRows(_ pairs: [LockPair: UInt64]) -> [PairRow] {
    pairs
        .map { PairRow(first: $0.key.first, second: $0.key.second, count: $0.value) }
        .sorted { ($0.first, $0.second) < ($1.first, $1.second) }
}
#endif
