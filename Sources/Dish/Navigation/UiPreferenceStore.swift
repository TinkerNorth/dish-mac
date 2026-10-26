// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Foundation

/// The window's own preferences, beside the engine's: whether the rail is an
/// icon strip. The desktops' key, so the setting reads the same everywhere.
struct UiPreferenceStore {
    static let railCollapsedKey = "ui_rail_collapsed"

    let defaults: UserDefaults

    var railCollapsed: Bool {
        defaults.bool(forKey: Self.railCollapsedKey)
    }

    func setRailCollapsed(_ collapsed: Bool) {
        defaults.set(collapsed, forKey: Self.railCollapsedKey)
    }
}
