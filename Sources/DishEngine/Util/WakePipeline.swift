// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Combine
import DishCore
import DishKernel
import Foundation

/// The keep-awake chain, built once by `AppModel`: the streaming count and
/// the pad activity composed with the preference into the `WakeState` the
/// inhibitor follows. Nothing here is started; the owner starts it.
@MainActor
struct WakePipeline {

    /// Bound slots whose connection streams.
    let streamingCount: Composer<Int>
    /// Whether a pad was used inside the keep-awake window.
    let activity: ControllerActivitySource
    /// How far the machine is held awake, from the count, the activity and
    /// the preferences.
    let wakeState: Composer<WakeState>
    /// The side effect that follows `wakeState`.
    let wake: WakeStateController

    init(hub: ConnectionHub, processor: GamepadInputProcessor, keepAwake: KeepAwakePreferenceStore, inhibitor: WakeInhibitor) {
        let streamingCount = Composer(hub.$bindings, hub.$connections, initial: 0, transform: streamingSlotCount)
        let activity = ControllerActivitySource(
            lastInputMs: { Int64(processor.lastInputMs.get()) },
            timeoutMs: { Int64(keepAwake.state.idleTimeoutMinutes) * 60000 },
            now: uptimeMs
        )
        let wakeState = Composer(
            streamingCount.statePublisher,
            activity.statePublisher,
            keepAwake.statePublisher,
            initial: WakeState(),
            transform: deriveWakeState
        )
        self.streamingCount = streamingCount
        self.activity = activity
        self.wakeState = wakeState
        wake = WakeStateController(upstream: wakeState.statePublisher, inhibitor: inhibitor)
    }

    /// Starts the activity clock and the inhibitor's following, in that order.
    func start() {
        activity.start()
        wake.start()
    }
}
