// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import DishEngine
import Foundation
import SwiftUI

/// The appearance a theme mode pins; nil follows the system.
func colorScheme(for mode: ThemeMode) -> ColorScheme? {
    switch mode {
    case .system: nil
    case .light: .light
    case .dark: .dark
    }
}

func themeModeText(_ mode: ThemeMode, words: L10n = .app) -> String {
    switch mode {
    case .system: words.themeSystem
    case .light: words.themeLight
    case .dark: words.themeDark
    }
}

func keepAwakeModeText(_ mode: KeepAwakeMode, words: L10n = .app) -> String {
    switch mode {
    case .off: words.off
    case .whileControllerActive: words.whilePlaying
    case .whileConnected: words.whileConnected
    }
}

/// The idle window's label.
func idleTimeoutText(_ minutes: Int, words: L10n = .app) -> String {
    words.minutes(minutes)
}

/// The Updates section's one status line, from the checker's state.
func updateStatusText(_ status: UpdateStatus, lastCheckMs: Int64, now: Date, words: L10n = .app) -> String {
    switch status.phase {
    case .disabled: words.updateChecksOff
    case .checking: words.checkingForUpdates
    case .available: words.updateAvailable(status.availableVersion)
    case .upToDate: words.onLatestVersion
    case .idle: lastCheckMs > 0 ? words.lastChecked(status.currentVersion, lastCheckText(lastCheckMs, now: now, words: words)) : words
        .noUpdateInformation
    case .failed: updateFailureText(status.error, words: words)
    }
}

func updateFailureText(_ error: UpdateError, words: L10n = .app) -> String {
    switch error {
    case .offline: words.updateOffline
    case .manifestInvalid: words.updateManifestInvalid
    case .http, .none: words.updateCheckFailed
    }
}

/// When the last check completed, relative to now.
func lastCheckText(_ lastCheckMs: Int64, now: Date, words: L10n = .app) -> String {
    guard lastCheckMs > 0 else { return words.never }
    let formatter = RelativeDateTimeFormatter()
    formatter.locale = words.catalog.locale
    formatter.unitsStyle = .full
    return formatter.localizedString(for: Date(timeIntervalSince1970: TimeInterval(lastCheckMs) / 1000), relativeTo: now)
}

/// Whether the Updates section offers the release page.
func showsReleasePage(_ status: UpdateStatus) -> Bool {
    status.phase == .available && !status.notesUrl.isEmpty
}
