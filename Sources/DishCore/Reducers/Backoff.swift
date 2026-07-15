// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// Pure exponential reconnect-backoff schedule (contract/android/dish-linux
// parity: 1s, 2s, 4s, … capped at 60s). Free function so the schedule is
// unit-testable without a clock or timer; the auto-reconnect tick gates each
// connection on the deadline this schedule produces instead of a blind
// fixed-period retry. Ports dish-linux Network/Backoff.h.

import Foundation

/// First silent retry lands after 1 s.
public let backoffBaseMs = 1000
/// The schedule is capped at 60 s between retries.
public let backoffMaxMs = 60000
/// `1000 << 6 == 64000` → capped to 60000; larger shifts would overflow
/// pointlessly, so the exponent is clamped here.
public let backoffMaxShift = 6

/// Delay before the `attempt`-th consecutive silent retry. `attempt` is
/// 1-based (the first retry after a death is attempt 1 → `backoffBaseMs`).
/// Clamped so a long outage doesn't overflow the shift or exceed the 60 s
/// ceiling. A non-positive attempt is treated as the first.
public func backoffDelayMs(attempt: Int) -> Int {
    let shift = attempt <= 1 ? 0 : min(attempt - 1, backoffMaxShift)
    return min(backoffBaseMs << shift, backoffMaxMs)
}
