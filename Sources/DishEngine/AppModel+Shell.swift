// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Combine
import DishCore
import Foundation

/// The facts the window's shell draws on every page: the streaming pill
/// reads the keep-awake reach, the Settings rail item the update check, and
/// the Settings page whether an earlier run left a crash log.
package struct ShellFacts: Equatable {
    package var wake = WakeState()
    package var update = UpdateStatus()
    package var crashLogPresent = false

    package init(wake: WakeState = WakeState(), update: UpdateStatus = UpdateStatus(), crashLogPresent: Bool = false) {
        self.wake = wake
        self.update = update
        self.crashLogPresent = crashLogPresent
    }
}

extension AppModel {

    func observeShellFacts() {
        shellFacts.crashLogPresent = crashLog.exists
        wakeState.statePublisher
            .sink { [weak self] wake in self?.shellFacts.wake = wake }
            .store(in: &cancellables)
        updates.statePublisher
            .sink { [weak self] update in self?.shellFacts.update = update }
            .store(in: &cancellables)
    }

    /// The crash log is read again, for a page that shows whether it waits.
    func refreshCrashLogPresence() {
        shellFacts.crashLogPresent = crashLog.exists
    }
}
