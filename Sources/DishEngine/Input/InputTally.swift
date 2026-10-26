// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Foundation

/// What each pad has produced so far: its published reports and its
/// admitted motion samples.
struct PadTally: Equatable {
    var reports: [String: UInt64] = [:]
    var motion: [String: UInt64] = [:]
}

/// The hot path's counts for the footers and the wire line, written on the
/// input queue under its own lock and read by the telemetry tick on the
/// main actor. One increment per event; nothing else is measured twice.
final class InputTally: @unchecked Sendable {
    private var tally = PadTally()
    private var lock = os_unfair_lock_s()

    func countReport(_ deviceId: String) {
        os_unfair_lock_lock(&lock)
        tally.reports[deviceId, default: 0] += 1
        os_unfair_lock_unlock(&lock)
    }

    func countMotion(_ deviceId: String) {
        os_unfair_lock_lock(&lock)
        tally.motion[deviceId, default: 0] += 1
        os_unfair_lock_unlock(&lock)
    }

    /// The pad left: its counts start over if it comes back.
    func forget(_ deviceId: String) {
        os_unfair_lock_lock(&lock)
        tally.reports.removeValue(forKey: deviceId)
        tally.motion.removeValue(forKey: deviceId)
        os_unfair_lock_unlock(&lock)
    }

    func snapshot() -> PadTally {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return tally
    }
}
