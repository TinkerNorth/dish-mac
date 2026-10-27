// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Combine
import DishCore
import Foundation

/// The input paths as intents: the "Not responding?" check and the user's
/// pick between Standard and Direct.
package extension AppModel {

    /// Watches both paths for five seconds on the pad's machine; the
    /// verdict lands in the slot's path facts and the flight recorder.
    func startInputCheck(slotId: String) {
        input.paths.startCheck(slotId: slotId)
    }

    /// Honoured only where `pathAvailable` allows the path; the pick is the
    /// model's, stored under `usb_path_choices`. Whether it was honoured.
    @discardableResult
    func pickInputPath(slotId: String, _ source: InputSource) -> Bool {
        input.paths.pick(slotId: slotId, source)
    }
}

extension AppModel {

    /// The paths' facts into the shell's, every decision into the flight
    /// recorder, the slot list into the player numbers, and the Direct pads'
    /// raw rates onto the ticks Diagnostics and the live rates already run.
    func observeInputPaths() {
        let paths = input.paths
        paths.statePublisher
            .sink { [weak self] facts in self?.shellFacts.inputPaths = facts }
            .store(in: &cancellables)
        paths.records
            .sink { [weak self] record in self?.recordInputPath(record) }
            .store(in: &cancellables)
        input.$slots
            .sink { [weak paths] slots in paths?.slotsChanged(slots.map(\.id)) }
            .store(in: &cancellables)
        diagnostics.useInputPaths(paths.facts(forSlot:), tick: paths.sampleRawRatesNow)
        telemetry.useTick(paths.sampleRawRatesNow)
    }

    /// Wall-clock milliseconds, as every other line of the log.
    private func recordInputPath(_ record: InputPathRecord) {
        let atMs = Int64(Date().timeIntervalSince1970 * 1000)
        diagnosticsLog.record([pathEvent(record.subject, record.note, atMs: atMs)])
    }
}
