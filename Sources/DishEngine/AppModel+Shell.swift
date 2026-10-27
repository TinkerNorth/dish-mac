// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Combine
import DishCore
import Foundation

/// The facts the window's shell and its pages draw beyond the slot list:
/// the streaming pill reads the keep-awake reach, the Settings rail item the
/// update check, the Settings page the preferences, the update clock and
/// whether an earlier run left a crash log, the crash report page that log,
/// the Connections pages what the scans heard and what they ask, the
/// controller pages the global switches, the stored dead zones, the live
/// rates and the binding being configured, and the Diagnostics pages what
/// the source, the flight recorder and the inspector read.
package struct ShellFacts: Equatable {
    package var wake = WakeState()
    package var update = UpdateStatus()
    /// When the last update check completed, against a clock that ticks
    /// every minute while Settings shows.
    package var updateClock = UpdateCheckTime()
    package var preferences = PreferenceFacts()
    package var crashLogPresent = false
    /// The crash log's text as last read, empty when there is none.
    package var crashLogText = ""
    package var diagnostics = DiagnosticsSnapshot()
    /// The flight recorder's lines, oldest first.
    package var diagnosticsEvents: [DiagnosticsEvent] = []
    /// The inspector's reading of the one controller it is armed on.
    package var inspection = InputInspection.disarmed
    package var connections = ConnectionsFacts()
    package var forwarding = ForwardingFlags()
    package var deadzones: [String: DeadzoneSetting] = [:]
    package var telemetry = InputTelemetry()
    package var binding = BindingFacts()
    /// The setup walk on screen, nil while none is.
    package var setup: SetupWizardState?
    /// A satellite is still registering a controller.
    package var controllerRegistering = false
    /// Each visible slot's input path: Standard or Direct, why, the check.
    package var inputPaths: [String: SlotInputPath] = [:]

    package init(wake: WakeState = WakeState(), update: UpdateStatus = UpdateStatus(), crashLogPresent: Bool = false) {
        self.wake = wake
        self.update = update
        self.crashLogPresent = crashLogPresent
    }
}

extension AppModel {

    func observeShellFacts() {
        refreshCrashLogPresence()
        wakeState.statePublisher
            .sink { [weak self] wake in self?.shellFacts.wake = wake }
            .store(in: &cancellables)
        updates.statePublisher
            .sink { [weak self] update in self?.shellFacts.update = update }
            .store(in: &cancellables)
        observeConnectionsFacts()
        observeForwarding()
        wifi.$anyControllerRegistering
            .sink { [weak self] registering in self?.shellFacts.controllerRegistering = registering }
            .store(in: &cancellables)
        observeTelemetry()
        observeBindingFacts()
        observeBindingMemory()
        observeSetup()
        observePreferences()
        observeDiagnosticsFacts()
        observeInputPaths()
    }

    /// The pages fold the global switches with each controller's own.
    private func observeForwarding() {
        settings.objectWillChange
            .afterMutationSettles()
            .map { _ in () }
            .prepend(())
            .sink { [weak self] in self?.refreshForwarding() }
            .store(in: &cancellables)
    }

    private func refreshForwarding() {
        shellFacts.forwarding = settings.flags
    }

    private func observeTelemetry() {
        telemetry.use(counts: { [weak self] in self?.inputCounts() ?? InputCounts() }, clockUs: uptimeUs)
        telemetry.statePublisher
            .sink { [weak self] rates in self?.shellFacts.telemetry = rates }
            .store(in: &cancellables)
    }

    private func inputCounts() -> InputCounts {
        let pads = input.processor.tally.snapshot()
        return InputCounts(reports: pads.reports, motion: pads.motion, sends: routing.sent.current())
    }

    /// The crash log is read again, for a page that shows whether it waits
    /// or what it says.
    func refreshCrashLogPresence() {
        shellFacts.crashLogPresent = crashLog.exists
        shellFacts.crashLogText = crashLog.read()
    }
}
