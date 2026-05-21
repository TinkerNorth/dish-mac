// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Foundation

/// Pure routing decisions for the satellite → dish *return path* (`MSG_RUMBLE`
/// and `MSG_LIGHTBAR`).
///
/// Rumble and the light bar are independent return paths, each gated by its
/// own `FeatureSettings` toggle. The actual fan-out lives in
/// `AppModel.installRumbleHandlers` / `installLightbarHandlers`, wrapped in a
/// main-actor hop and a binding lookup that need a live `GameControllerInput`.
/// The *decision* of whether a sink fires, though, is pure: it depends only on
/// a `ForwardingFlags` snapshot.
///
/// That decision is factored out here so it can be unit-tested without driving
/// a socket or a real controller — the same "pure seam" pattern as
/// `SatelliteClient.parseRumblePayload` / `parseLightbarMessage` on the decode
/// side. `AppModel`'s handlers call straight into these functions.
enum ReturnPathRouting {

    /// Whether a decoded `MSG_RUMBLE` should drive the haptics. Gated solely
    /// on the Rumble toggle.
    static func shouldVibrate(flags: ForwardingFlags) -> Bool {
        flags.rumble
    }

    /// Whether a decoded `MSG_LIGHTBAR` colour should reach the controller.
    /// Gated solely on the Light bar setting.
    static func shouldApply(lightbar _: SatelliteClient.LightbarMessage, flags: ForwardingFlags) -> Bool {
        flags.lightbar
    }
}
