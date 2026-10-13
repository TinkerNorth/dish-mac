// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Combine
import DishCore
import DishKernel
import Foundation

/// Drives the wake inhibitor off the composed `WakeState`. Starting applies
/// the current value at once, so a controller started mid-stream holds
/// immediately; stopping lets go, so a hold is never stranded.
final class WakeStateController: Controller<WakeState> {

    private let inhibitor: WakeInhibitor
    private let reason: String
    private(set) var current = WakeState()

    init(
        upstream: AnyPublisher<WakeState, Never>,
        inhibitor: WakeInhibitor,
        reason: String = "Dish is streaming gamepad input to Satellite"
    ) {
        self.inhibitor = inhibitor
        self.reason = reason
        super.init(upstream: upstream)
    }

    override func apply(_ value: WakeState) {
        current = value
        switch value.reach {
        case .none: inhibitor.release()
        case .system, .systemAndDisplay: inhibitor.hold(value.reach, reason: reason)
        }
    }

    override func stop() {
        super.stop()
        inhibitor.release()
    }
}

/// Bound slots whose connection is online or unsteady; an unsteady link
/// still carries packets and must not drop the hold.
func streamingCount(bindings: [String: String], connectionStates: [String: LinkState]) -> Int {
    bindings.values.filter { connectionId in
        let state = connectionStates[connectionId]
        return state == .connected || state == .unstable
    }.count
}

/// The streaming-slot count from the hub's bindings and summaries, for the
/// composer that feeds the wake state.
func streamingSlotCount(bindings: [String: String], summaries: [ConnectionSummary]) -> Int {
    let states = Dictionary(uniqueKeysWithValues: summaries.map { ($0.id, $0.live) })
    return streamingCount(bindings: bindings, connectionStates: states)
}
