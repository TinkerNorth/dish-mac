// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Combine
import DishKernel
import Foundation

/// Holds a `DisplaySleepInhibitor` while any bound slot streams. The
/// upstream is the count of bound, connected slots; the assertion flips only
/// when the count crosses zero.
final class ScreenWakeController: Controller<Int> {

    private let inhibitor: DisplaySleepInhibitor
    private let reason: String
    private(set) var streamingSlotCount = 0

    init(
        upstream: AnyPublisher<Int, Never>,
        inhibitor: DisplaySleepInhibitor,
        reason: String = "Dish is streaming gamepad input to Satellite"
    ) {
        self.inhibitor = inhibitor
        self.reason = reason
        super.init(upstream: upstream)
    }

    /// Bound slots whose connection is online or unsteady; an unsteady link
    /// still carries packets and must not drop the assertion.
    static func streamingCount(bindings: [String: String], connectionStates: [String: LinkState]) -> Int {
        bindings.values.filter { connectionId in
            let state = connectionStates[connectionId]
            return state == .connected || state == .unstable
        }.count
    }

    override func apply(_ count: Int) {
        let was = streamingSlotCount
        streamingSlotCount = count
        let startedStreaming = was == 0 && count > 0
        let stoppedStreaming = was > 0 && count == 0
        if startedStreaming {
            inhibitor.acquire(reason: reason)
        }
        if stoppedStreaming {
            inhibitor.release()
        }
    }

    /// Drop the assertion whatever the count; the next `apply` starts over.
    func reset() {
        streamingSlotCount = 0
        inhibitor.release()
    }
}

/// The streaming-slot count from the hub's bindings and summaries, for the
/// composer that feeds the wake controller.
func streamingSlotCount(bindings: [String: String], summaries: [ConnectionSummary]) -> Int {
    let states = Dictionary(uniqueKeysWithValues: summaries.map { ($0.id, $0.live) })
    return ScreenWakeController.streamingCount(bindings: bindings, connectionStates: states)
}
