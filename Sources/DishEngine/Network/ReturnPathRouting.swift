// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import Foundation

/// The pure decisions of the satellite → dish return path (`MSG_RUMBLE` and
/// `MSG_LIGHTBAR`): whether a decoded command reaches the pad, from a
/// `ForwardingFlags` snapshot alone. `ReturnPathRouter` does the fan-out;
/// the two paths are independent, each behind its own switch.
enum ReturnPathRouting {

    /// Whether a decoded `MSG_RUMBLE` should drive the haptics. Gated solely
    /// on the Rumble toggle.
    static func shouldVibrate(flags: ForwardingFlags) -> Bool {
        flags.rumble
    }

    /// Whether a decoded `MSG_LIGHTBAR` colour should reach the controller.
    /// Gated solely on the Light bar setting.
    static func shouldApply(lightbar _: LightbarCommand, flags: ForwardingFlags) -> Bool {
        flags.lightbar
    }
}
