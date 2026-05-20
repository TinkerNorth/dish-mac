// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Foundation

/// Owns the "are we streaming?" boolean and drives a `DisplaySleepInhibitor`
/// off it. Mirrors `dish-android :: WakeStateController` — there
/// `streamingSlotCount` is derived from `hub.bindings × hub.connections`;
/// here the AppModel feeds the same derived signal in via `update(...)`.
///
/// Pure logic — no IOKit, no Combine subscription. The AppModel decides when
/// to call `update`, and the controller only flips the inhibitor when the
/// boolean crosses zero. Lets tests pin the transition contract directly.
final class ScreenWakeController {

    private let inhibitor: DisplaySleepInhibitor
    private let reason: String
    private(set) var streamingSlotCount = 0

    init(
        inhibitor: DisplaySleepInhibitor,
        reason: String = "Dish is streaming gamepad input to Satellite"
    ) {
        self.inhibitor = inhibitor
        self.reason = reason
    }

    /// Pure helper that derives the count of bound + connected slots from the
    /// current binding table and the per-connection state. Extracted so unit
    /// tests can pin the arithmetic without instantiating a controller.
    ///
    /// `.unstable` (faltering session) still counts as streaming — packets
    /// are still flowing, just with heartbeat wobble — so an unsteady slot
    /// must not drop the wake lock.
    static func streamingCount(
        bindings: [String: String],
        connectionStates: [String: LinkState]
    ) -> Int {
        var count = 0
        for (_, cid) in bindings {
            switch connectionStates[cid] {
            case .connected, .unstable: count += 1
            default: break
            }
        }
        return count
    }

    /// Feed the controller a fresh streaming count. Acquires the inhibitor on
    /// the 0 → positive transition; releases on positive → 0. Same value
    /// twice in a row is a no-op so callers can spam updates without thrash.
    func update(streamingSlotCount: Int) {
        let was = self.streamingSlotCount
        self.streamingSlotCount = streamingSlotCount
        if was == 0, streamingSlotCount > 0 {
            inhibitor.acquire(reason: reason)
        } else if was > 0, streamingSlotCount == 0 {
            inhibitor.release()
        }
    }

    /// Backgrounding / window-close path. Drops the inhibitor unconditionally
    /// and resets the count so the next `update` re-establishes from scratch.
    func reset() {
        streamingSlotCount = 0
        inhibitor.release()
    }
}
