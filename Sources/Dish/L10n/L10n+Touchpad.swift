// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Foundation

extension L10n {

    // MARK: - The touchpad picker

    var pad: String {
        catalog.text("Pad")
    }

    var touchpadPickerHelp: String {
        catalog.text("Send the touchpad as a touchpad, or route it as a mouse.")
    }

    var touchpadForwardedAsTouchpad: String {
        catalog.text("Forwards this pad’s touchpad to the game as a touchpad.")
    }

    var touchpadRoutingOff: String {
        catalog.text("Touchpad routing is off for this binding.")
    }

    var touchpadMovesTheMouse: String {
        catalog.text("The touchpad moves the host’s mouse; the pad’s click is the left button.")
    }
}
