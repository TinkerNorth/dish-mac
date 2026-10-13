// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import DishKernel
import Foundation

/// The switches a controller carries on its own, beneath the global ones in
/// Settings: motion, rumble and the touchpad's pick (the pad render, the
/// host's mouse, or off), and the pad's own microphone and speaker. The
/// light bar stays global, as on the other desktop clients. An unwritten
/// switch is on, the touchpad renders the pad, and the microphone is off
/// until asked.
package struct SlotPreferences: Hashable {
    package var motion = true
    package var rumble = true
    package var touchpad = TouchpadPick.pad
    package var mic = false
    package var speaker = true

    package init(motion: Bool = true, rumble: Bool = true, touchpad: TouchpadPick = .pad, mic: Bool = false, speaker: Bool = true) {
        self.motion = motion
        self.rumble = rumble
        self.touchpad = touchpad
        self.mic = mic
        self.speaker = speaker
    }
}

/// The switches a controller carries, for the intent that flips one.
package enum SlotSwitch: Equatable {
    case motion
    case rumble
    case touchpad
    case mic
    case speaker
}

/// The switches that reach the wire and the hot path for one controller:
/// the global switch and the controller's own, both on. The light bar has
/// no per-controller switch; the pad's audio has no global one; the
/// touchpad's pick is the controller's alone, sent at all only while the
/// global switch is on.
package func effectiveFlags(global: ForwardingFlags, slot: SlotPreferences) -> ForwardingFlags {
    ForwardingFlags(
        motion: global.motion && slot.motion,
        touchpad: global.touchpad && slot.touchpad != .off,
        rumble: global.rumble && slot.rumble,
        lightbar: global.lightbar,
        mic: slot.mic,
        speaker: slot.speaker,
        touchpadPick: slot.touchpad
    )
}

/// The per-controller switches, keyed by the slot's stable id, kept in
/// `UserDefaults` as the fleet keeps them: one JSON array per feature under
/// `motion_preferences`, `rumble_preferences` and `touchpad_preferences`,
/// each row `{"slotId": …, "enabled": …}`, and the touchpad's pick under
/// `touchpad_mode_preferences`, each row `{"slotId": …, "mode": …}` in the
/// wire's words. A pick never written reads the older on/off row, so an
/// upgrade keeps every switch. A garbled blob reads as an empty list: losing
/// the switches beats bricking startup.
@MainActor
package final class SlotPreferenceStore: StateSource<[String: SlotPreferences]> {

    static let motionKey = "motion_preferences"
    static let rumbleKey = "rumble_preferences"
    static let touchpadKey = "touchpad_preferences"
    static let touchpadModeKey = "touchpad_mode_preferences"
    static let micKey = "mic_preferences"
    static let speakerKey = "speaker_preferences"

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

    /// The chip's click: off, or the pad render again.
    package func setTouchpad(_ enabled: Bool, for slotId: String) {
        update(slotId) { $0.touchpad = enabled ? .pad : .off }
    }

    package func setTouchpadPick(_ pick: TouchpadPick, for slotId: String) {
        update(slotId) { $0.touchpad = pick }
    }

    package func setMic(_ enabled: Bool, for slotId: String) {
        update(slotId) { $0.mic = enabled }
    }

    package func setSpeaker(_ enabled: Bool, for slotId: String) {
        update(slotId) { $0.speaker = enabled }
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

    /// The on/off touchpad row is written beside the pick, so an older
    /// build of this app still reads a switch.
    private func write(_ all: [String: SlotPreferences]) {
        defaults.set(Self.rows(all) { $0.motion }, forKey: Self.motionKey)
        defaults.set(Self.rows(all) { $0.rumble }, forKey: Self.rumbleKey)
        defaults.set(Self.rows(all) { $0.touchpad != .off }, forKey: Self.touchpadKey)
        defaults.set(Self.modeRows(all), forKey: Self.touchpadModeKey)
        defaults.set(Self.rows(all) { $0.mic }, forKey: Self.micKey)
        defaults.set(Self.rows(all) { $0.speaker }, forKey: Self.speakerKey)
    }

    /// One row per controller, in a stable order, as the fleet's JSON shape.
    private static func rows(_ all: [String: SlotPreferences], _ enabled: (SlotPreferences) -> Bool) -> String {
        encode(all.keys.sorted().map { ["slotId": $0, "enabled": enabled(all[$0] ?? SlotPreferences())] as [String: Any] })
    }

    private static func modeRows(_ all: [String: SlotPreferences]) -> String {
        encode(all.keys.sorted().map { ["slotId": $0, "mode": (all[$0] ?? SlotPreferences()).touchpad.wireName] as [String: Any] })
    }

    private static func encode(_ rows: [[String: Any]]) -> String {
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
            all[slotId, default: SlotPreferences()].touchpad = enabled ? .pad : .off
        }
        for (slotId, mode) in parseModes(defaults.string(forKey: touchpadModeKey)) {
            all[slotId, default: SlotPreferences()].touchpad = mode
        }
        for (slotId, enabled) in parse(defaults.string(forKey: micKey)) {
            all[slotId, default: SlotPreferences()].mic = enabled
        }
        for (slotId, enabled) in parse(defaults.string(forKey: speakerKey)) {
            all[slotId, default: SlotPreferences()].speaker = enabled
        }
        return all
    }

    /// The rows of one feature's list; anything but a list of
    /// `{slotId, enabled}` rows reads as nothing written.
    static func parse(_ json: String?) -> [(String, Bool)] {
        rows(json).compactMap { row in
            guard let slotId = row["slotId"] as? String, !slotId.isEmpty, let enabled = row["enabled"] as? Bool else { return nil }
            return (slotId, enabled)
        }
    }

    /// The rows of the pick list; a row whose mode is not a wire word is
    /// skipped, so the on/off row beneath it still speaks.
    static func parseModes(_ json: String?) -> [(String, TouchpadPick)] {
        rows(json).compactMap { row in
            guard let slotId = row["slotId"] as? String, !slotId.isEmpty, let mode = row["mode"] as? String else { return nil }
            guard isValidTouchpadPickName(mode) else { return nil }
            return (slotId, TouchpadPick(wireName: mode))
        }
    }

    private static func rows(_ json: String?) -> [[String: Any]] {
        guard let json, let rows = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]] else { return [] }
        return rows
    }
}
