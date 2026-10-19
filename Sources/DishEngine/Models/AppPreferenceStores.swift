// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Foundation

/// The preference stores the composition root owns, one per fleet key,
/// over one defaults suite: built together so the root's init stays a list
/// of what it wires rather than of what it stores.
struct AppPreferenceStores {
    let settings: FeatureSettings
    let theme: ThemePreferenceStore
    let background: BackgroundPreferenceStore
    let keepAwake: KeepAwakePreferenceStore
    let updates: UpdatePreferenceStore
    let slots: SlotPreferenceStore

    @MainActor
    init(defaults: UserDefaults) {
        settings = FeatureSettings(defaults: defaults)
        theme = ThemePreferenceStore(defaults: defaults)
        background = BackgroundPreferenceStore(defaults: defaults)
        keepAwake = KeepAwakePreferenceStore(defaults: defaults)
        updates = UpdatePreferenceStore(defaults: defaults)
        slots = SlotPreferenceStore(defaults: defaults)
    }
}
