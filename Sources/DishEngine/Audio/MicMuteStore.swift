// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishKernel
import Foundation

/// Which controllers' microphones are muted, by slot id. Live state for
/// this run only, as on the other clients: a relaunch starts unmuted, so a
/// microphone is never open without the user having asked this time.
@MainActor
package final class MicMuteStore: StateSource<Set<String>> {

    package init() {
        super.init(initial: [])
    }

    package func isMuted(_ slotId: String) -> Bool {
        state.contains(slotId)
    }

    package func setMuted(_ muted: Bool, for slotId: String) {
        updateState { current in
            var next = current
            if muted {
                next.insert(slotId)
            } else {
                next.remove(slotId)
            }
            return next
        }
    }

    /// The chip's tap: every armed microphone, all or nothing.
    package func setMuted(_ muted: Bool, for slotIds: some Sequence<String>) {
        updateState { current in
            muted ? current.union(slotIds) : current.subtracting(slotIds)
        }
    }

    /// A departed pad takes its mute with it.
    package func retainOnly(_ slotIds: Set<String>) {
        updateState { $0.intersection(slotIds) }
    }
}
