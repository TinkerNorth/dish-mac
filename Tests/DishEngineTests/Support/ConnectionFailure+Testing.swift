// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

@testable import DishEngine

extension ConnectionFailure {
    /// The generic "the satellite answered without a grant" failure, whatever
    /// detail it carried.
    var isSessionRefused: Bool {
        if case .sessionRefused = self { return true }
        return false
    }
}
