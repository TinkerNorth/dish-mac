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
    private var lock = TrackedLock(os_unfair_lock_s(), "input.tally")

    func countReport(_ deviceId: String) {
        lock.lock()
        tally.reports[deviceId, default: 0] += 1
        lock.unlock()
    }

    func countMotion(_ deviceId: String) {
        lock.lock()
        tally.motion[deviceId, default: 0] += 1
        lock.unlock()
    }

    /// The pad left: its counts start over if it comes back.
    func forget(_ deviceId: String) {
        lock.lock()
        tally.reports.removeValue(forKey: deviceId)
        tally.motion.removeValue(forKey: deviceId)
        lock.unlock()
    }

    func snapshot() -> PadTally {
        lock.lock()
        defer { lock.unlock() }
        return tally
    }
}
