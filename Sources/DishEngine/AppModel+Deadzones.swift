// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Combine
import DishCore
import Foundation

/// The Dead zones page's intents: each attached pad gets the zones stored
/// for it, or the defaults, as it attaches and whenever they change; the
/// page reads what is stored from the shell's facts.
package extension AppModel {

    /// The emitted values are used, not the properties: `@Published`
    /// delivers before the write lands, and recording a slot is what hands
    /// a pad its zones before its first report.
    internal func observeDeadzones() {
        Publishers.CombineLatest(input.$slots, deadzonePreferences.statePublisher)
            .sink { [weak self] slots, stored in self?.applyDeadzones(slots: slots, stored: stored) }
            .store(in: &cancellables)
    }

    private func applyDeadzones(slots: [GameControllerInput.Slot], stored: [String: DeadzoneSetting]) {
        for slot in slots {
            let zones = stored[slot.id] ?? .defaults
            input.processor.setDeadzones(deviceId: slot.id, processorZones(zones))
        }
        shellFacts.deadzones = stored
    }

    func setStickDeadzone(percent: Int, slotId: String) {
        let current = deadzonePreferences.zones(for: slotId)
        deadzonePreferences.setZones(current.withStickPercent(percent), for: slotId)
    }

    func setTriggerDeadzone(percent: Int, slotId: String) {
        let current = deadzonePreferences.zones(for: slotId)
        deadzonePreferences.setZones(current.withTriggerPercent(percent), for: slotId)
    }

    /// The pad's tuning is forgotten; the defaults apply again.
    func resetDeadzones(slotId: String) {
        deadzonePreferences.reset(slotId)
    }
}

func processorZones(_ zones: DeadzoneSetting) -> GamepadInputProcessor.Deadzones {
    GamepadInputProcessor.Deadzones(stickFlat: zones.stickFlat, triggerFlat: zones.triggerFlat)
}
