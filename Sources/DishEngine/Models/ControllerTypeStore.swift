// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishKernel
import Foundation

/// The user's per-binding "Emulate as" override: (satellite, pad) → catalog
/// type. The picker writes here; the connection layer reads it when it
/// builds the descriptor. Live state for this run, as on the other clients:
/// no override means the pad's family picks its type.
@MainActor
package final class ControllerTypeStore: StateSource<[SlotKey: Int]> {

    package init() {
        super.init(initial: [:])
    }

    package func typeFor(_ key: SlotKey) -> Int? {
        state[key]
    }

    package func setType(_ type: Int, for key: SlotKey) {
        updateState { current in
            var next = current
            next[key] = type
            return next
        }
    }

    /// Back to the family's own type. A no-op for a binding with no override.
    package func clear(_ key: SlotKey) {
        updateState { current in
            var next = current
            next.removeValue(forKey: key)
            return next
        }
    }

    /// Every override under a satellite goes with it when it is forgotten.
    package func clearConnection(_ connectionId: String) {
        updateState { current in
            current.filter { $0.key.connectionId != connectionId }
        }
    }
}
