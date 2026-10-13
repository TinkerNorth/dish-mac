// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishKernel
import Foundation

/// The switches a controller carries on its own, beneath the global ones in
/// Settings: motion, rumble and the touchpad. The light bar stays global, as
/// on the other desktop clients. An unwritten switch is on.
package struct SlotPreferences: Hashable {
    package var motion = true
    package var rumble = true
    package var touchpad = true

    package init(motion: Bool = true, rumble: Bool = true, touchpad: Bool = true) {
        self.motion = motion
        self.rumble = rumble
        self.touchpad = touchpad
    }
}

/// The three switches a controller carries, for the intent that flips one.
package enum SlotSwitch: Equatable {
    case motion
    case rumble
    case touchpad
}

/// The switches that reach the wire and the hot path for one controller:
/// the global switch and the controller's own, both on. The light bar has
/// no per-controller switch.
package func effectiveFlags(global: ForwardingFlags, slot: SlotPreferences) -> ForwardingFlags {
    ForwardingFlags(
        motion: global.motion && slot.motion,
        touchpad: global.touchpad && slot.touchpad,
        rumble: global.rumble && slot.rumble,
        lightbar: global.lightbar
    )
}

/// The per-controller switches, keyed by the slot's stable id, kept in
/// `UserDefaults` as the fleet keeps them: one JSON array per feature under
/// `motion_preferences`, `rumble_preferences` and `touchpad_preferences`,
/// each row `{"slotId": …, "enabled": …}`. A garbled blob reads as an empty
/// list: losing the switches beats bricking startup.
@MainActor
package final class SlotPreferenceStore: StateSource<[String: SlotPreferences]> {

    static let motionKey = "motion_preferences"
    static let rumbleKey = "rumble_preferences"
    static let touchpadKey = "touchpad_preferences"

    private let defaults: UserDefaults

    package init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        super.init(initial: Self.read(defaults))
    }

    /// A controller never switched reads as all on.
    package func preferences(for slotId: String) -> SlotPreferences {
        state[slotId] ?? SlotPreferences()
    }

    package func setMotion(_ enabled: Bool, for slotId: String) {
        update(slotId) { $0.motion = enabled }
    }

    package func setRumble(_ enabled: Bool, for slotId: String) {
        update(slotId) { $0.rumble = enabled }
    }

    package func setTouchpad(_ enabled: Bool, for slotId: String) {
        update(slotId) { $0.touchpad = enabled }
    }

    private func update(_ slotId: String, _ change: (inout SlotPreferences) -> Void) {
        var next = preferences(for: slotId)
        change(&next)
        updateState { current in
            var all = current
            all[slotId] = next
            return all
        }
        write(state)
    }

    private func write(_ all: [String: SlotPreferences]) {
        defaults.set(Self.rows(all, \.motion), forKey: Self.motionKey)
        defaults.set(Self.rows(all, \.rumble), forKey: Self.rumbleKey)
        defaults.set(Self.rows(all, \.touchpad), forKey: Self.touchpadKey)
    }

    /// One row per controller, in a stable order, as the fleet's JSON shape.
    private static func rows(_ all: [String: SlotPreferences], _ feature: KeyPath<SlotPreferences, Bool>) -> String {
        let rows = all.keys.sorted().map { ["slotId": $0, "enabled": all[$0]?[keyPath: feature] ?? true] as [String: Any] }
        let data = try? JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys])
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }

    private static func read(_ defaults: UserDefaults) -> [String: SlotPreferences] {
        var all: [String: SlotPreferences] = [:]
        for (slotId, enabled) in parse(defaults.string(forKey: motionKey)) {
            all[slotId, default: SlotPreferences()].motion = enabled
        }
        for (slotId, enabled) in parse(defaults.string(forKey: rumbleKey)) {
            all[slotId, default: SlotPreferences()].rumble = enabled
        }
        for (slotId, enabled) in parse(defaults.string(forKey: touchpadKey)) {
            all[slotId, default: SlotPreferences()].touchpad = enabled
        }
        return all
    }

    /// The rows of one feature's list; anything but a list of
    /// `{slotId, enabled}` rows reads as nothing written.
    static func parse(_ json: String?) -> [(String, Bool)] {
        guard let json, let rows = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let slotId = row["slotId"] as? String, !slotId.isEmpty, let enabled = row["enabled"] as? Bool else { return nil }
            return (slotId, enabled)
        }
    }
}
