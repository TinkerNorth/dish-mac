// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import DishEngine
import Foundation

/// The light-bar picker's option words.
func lightbarModeText(_ mode: LightbarMode, words: L10n = .app) -> String {
    switch mode {
    case .followGame: words.followGame
    case .off: words.off
    }
}

/// Which of Settings' conditional rows show, and the version line.
struct SettingsPageState: Equatable {
    /// The stillness stepper, only while keep-awake waits on a used pad.
    let showsIdleTimeout: Bool
    /// The display switch, only while keep-awake holds anything at all.
    let showsDisplayAwake: Bool
    /// This build carries no reporting address, so the switch sends nothing.
    let showsUploadImpossible: Bool
    /// The crash-report row, only while an earlier run left a log.
    let showsCrashReport: Bool
    let aboutLine: String
}

func settingsPageState(
    keepAwake: KeepAwakePreferences,
    uploadPossible: Bool,
    facts: ShellFacts,
    words: L10n = .app
) -> SettingsPageState {
    SettingsPageState(
        showsIdleTimeout: keepAwake.mode == .whileControllerActive,
        showsDisplayAwake: keepAwake.mode != .off,
        showsUploadImpossible: !uploadPossible,
        showsCrashReport: facts.crashLogPresent,
        aboutLine: words.aboutLine(facts.update.currentVersion)
    )
}
