// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishEngine
import Foundation

/// The light-bar picker's option words.
func lightbarModeText(_ mode: LightbarMode, words: L10n = .app) -> String {
    switch mode {
    case .followGame: words.followGame
    case .off: words.off
    }
}
