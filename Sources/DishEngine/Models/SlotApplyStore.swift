// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishKernel
import Foundation

/// What the satellite answered for one binding's slot: the result word, the
/// type it applied and the backend that carries it.
package struct SlotApplyAnswer: Equatable {
    package let result: String
    package let appliedType: Int
    package let backend: String?

    package init(result: String, appliedType: Int, backend: String?) {
        self.result = result
        self.appliedType = appliedType
        self.backend = backend
    }
}

/// The satellite's last answer per binding, as the apply results report it,
/// for the diagnostics bundle's session slots. Written by the connection
/// manager after every descriptor PUT, cleared with the connection.
@MainActor
package final class SlotApplyStore: StateSource<[SlotKey: SlotApplyAnswer]> {

    package init() {
        super.init(initial: [:])
    }

    package func setAnswer(_ answer: SlotApplyAnswer, for key: SlotKey) {
        updateState { current in
            var next = current
            next[key] = answer
            return next
        }
    }

    package func clear(_ key: SlotKey) {
        updateState { current in
            var next = current
            next.removeValue(forKey: key)
            return next
        }
    }

    package func clearConnection(_ connectionId: String) {
        updateState { current in
            current.filter { $0.key.connectionId != connectionId }
        }
    }
}
