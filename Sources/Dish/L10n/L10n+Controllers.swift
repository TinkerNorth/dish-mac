// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Foundation

extension L10n {

    // MARK: - Controllers: a card per pad

    func boundToHost(_ host: String) -> String {
        catalog.format("Bound · %@ ›", host)
    }

    var notBoundLower: String {
        catalog.text("not bound")
    }

    var noTouchpad: String {
        catalog.text("No touchpad")
    }

    func motionHz(_ hz: Int) -> String {
        catalog.format("Motion %lld Hz", hz)
    }

    var deadZonesEllipsis: String {
        catalog.text("Dead zones…")
    }

    func batteryPercentRising(_ level: Int) -> String {
        catalog.format("Battery %lld%% ↑", level)
    }
}
