// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Combine
import DishCore
import Foundation

/// The preferences Settings draws beyond the global switches (which the
/// controller pages read too, as `ShellFacts.forwarding`): each store's
/// state, mirrored so a page reads one published value.
package struct PreferenceFacts: Equatable {
    package var theme = ThemeMode.system
    package var lightbar = LightbarMode.followGame
    package var runInBackground = true
    package var keepAwake = KeepAwakePreferences()
    package var crashReportsShared = true
    /// This build carries a reporting address, so the switch can send.
    package var crashUploadPossible = false
    package var updateChecksEnabled = true

    package init(
        theme: ThemeMode = .system,
        keepAwake: KeepAwakePreferences = KeepAwakePreferences(),
        crashUploadPossible: Bool = false
    ) {
        self.theme = theme
        self.keepAwake = keepAwake
        self.crashUploadPossible = crashUploadPossible
    }
}

/// Settings' intents: every store setter a page may reach, and the update
/// check's two actions. A page never holds a store.
package extension AppModel {

    func setThemeMode(_ mode: ThemeMode) {
        theme.setMode(mode)
    }

    func setRumbleForwarded(_ on: Bool) {
        settings.rumbleEnabled = on
    }

    func setTouchpadForwarded(_ on: Bool) {
        settings.touchpadEnabled = on
    }

    func setMotionForwarded(_ on: Bool) {
        settings.motionEnabled = on
    }

    func setLightbarMode(_ mode: LightbarMode) {
        settings.lightbarMode = mode
    }

    func setRunInBackground(_ on: Bool) {
        background.setRunInBackground(on)
    }

    func setKeepAwakeMode(_ mode: KeepAwakeMode) {
        keepAwake.setMode(mode)
    }

    func setIdleTimeoutMinutes(_ minutes: Int) {
        keepAwake.setIdleTimeoutMinutes(minutes)
    }

    func setKeepDisplayAwake(_ on: Bool) {
        keepAwake.setKeepDisplayAwake(on)
    }

    func setCrashReportsShared(_ on: Bool) {
        crashReporting.setEnabled(on)
    }

    func setUpdateChecksEnabled(_ on: Bool) {
        updatePreferences.setChecksEnabled(on)
    }

    /// Rate-limited by the checker, so a held-down button cannot hammer the permalink.
    func checkForUpdatesNow() {
        updates.checkNow()
    }

    /// Mutes the offered version until the manifest offers a newer one.
    func skipAvailableUpdate() {
        updates.skipAvailableVersion()
    }
}

extension AppModel {

    func observePreferences() {
        shellFacts.preferences.crashUploadPossible = crashReporting.uploadPossible
        observePreferenceStores()
        settings.objectWillChange
            .afterMutationSettles()
            .map { _ in () }
            .prepend(())
            .sink { [weak self] in self?.refreshLightbar() }
            .store(in: &cancellables)
        updates.clock.statePublisher
            .sink { [weak self] time in self?.shellFacts.updateClock = time }
            .store(in: &cancellables)
    }

    private func observePreferenceStores() {
        theme.statePublisher
            .sink { [weak self] mode in self?.shellFacts.preferences.theme = mode }
            .store(in: &cancellables)
        background.statePublisher
            .sink { [weak self] state in self?.shellFacts.preferences.runInBackground = state.runInBackground }
            .store(in: &cancellables)
        keepAwake.statePublisher
            .sink { [weak self] state in self?.shellFacts.preferences.keepAwake = state }
            .store(in: &cancellables)
        crashReporting.statePublisher
            .sink { [weak self] shared in self?.shellFacts.preferences.crashReportsShared = shared }
            .store(in: &cancellables)
        updatePreferences.statePublisher
            .sink { [weak self] state in self?.shellFacts.preferences.updateChecksEnabled = state.checksEnabled }
            .store(in: &cancellables)
    }

    private func refreshLightbar() {
        shellFacts.preferences.lightbar = settings.lightbarMode
    }
}
