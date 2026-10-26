// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import DishEngine
import Foundation
import SwiftUI

/// The light-bar picker's option words.
func lightbarModeText(_ mode: LightbarMode, words: L10n = .app) -> String {
    switch mode {
    case .followGame: words.followGame
    case .off: words.off
    }
}

/// Everything Settings draws: each preference's current value, which of
/// the conditional rows show, the update row and the version line. Every
/// control reads its value here and writes it through an intent.
struct SettingsPageState: Equatable {
    let theme: ThemeMode
    let rumble: Bool
    let touchpad: Bool
    let lightbar: LightbarMode
    let motion: Bool
    let runInBackground: Bool
    let keepAwake: KeepAwakePreferences
    /// The stillness stepper, only while keep-awake waits on a used pad.
    let showsIdleTimeout: Bool
    /// The display switch, only while keep-awake holds anything at all.
    let showsDisplayAwake: Bool
    let crashReportsShared: Bool
    /// This build carries no reporting address, so the switch sends nothing.
    let showsUploadImpossible: Bool
    /// The crash-report row, only while an earlier run left a log.
    let showsCrashReport: Bool
    let update: UpdateRowState
    let updateChecksEnabled: Bool
    let aboutLine: String
}

/// The Updates section's status line and which of its buttons act.
struct UpdateRowState: Equatable {
    let status: String
    /// The error tone when this build is below the supported minimum.
    let statusColor: Color
    let canCheck: Bool
    /// Nil hides Open release page.
    let releasePage: URL?
    /// Skip this version, beside the release page unless the update is required.
    let offersSkip: Bool
}

func settingsPageState(facts: ShellFacts, words: L10n = .app) -> SettingsPageState {
    let preferences = facts.preferences
    return SettingsPageState(
        theme: preferences.theme,
        rumble: facts.forwarding.rumble,
        touchpad: facts.forwarding.touchpad,
        lightbar: preferences.lightbar,
        motion: facts.forwarding.motion,
        runInBackground: preferences.runInBackground,
        keepAwake: preferences.keepAwake,
        showsIdleTimeout: preferences.keepAwake.mode == .whileControllerActive,
        showsDisplayAwake: preferences.keepAwake.mode != .off,
        crashReportsShared: preferences.crashReportsShared,
        showsUploadImpossible: !preferences.crashUploadPossible,
        showsCrashReport: facts.crashLogPresent,
        update: updateRow(facts.update, time: facts.updateClock, words: words),
        updateChecksEnabled: preferences.updateChecksEnabled,
        aboutLine: words.aboutLine(facts.update.currentVersion)
    )
}

func updateRow(_ status: UpdateStatus, time: UpdateCheckTime, words: L10n = .app) -> UpdateRowState {
    let releasePage = showsReleasePage(status) ? URL(string: status.notesUrl) : nil
    return UpdateRowState(
        status: updateStatusText(status, time: time, words: words),
        statusColor: status.required ? DishTheme.error : DishTheme.onSurface,
        canCheck: updateCheckAllowed(status.phase),
        releasePage: releasePage,
        offersSkip: releasePage != nil && !status.required
    )
}
