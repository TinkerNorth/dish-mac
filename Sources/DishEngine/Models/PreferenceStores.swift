// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// The scalar user preferences, each a `StateSource` straight over
// `UserDefaults`. Every setter persists and republishes, and is idempotent:
// a repeat set does not re-emit, so a subscriber cannot loop through its own
// write. The keys are the fleet's, so a profile reads the same on every Dish.

import DishCore
import DishKernel
import Foundation

/// Which appearance the user chose.
@MainActor
package final class ThemePreferenceStore: StateSource<ThemeMode> {
    static let modeKey = "theme_mode"

    private let defaults: UserDefaults

    package init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        super.init(initial: ThemeMode.fromStorage(defaults.string(forKey: Self.modeKey)))
    }

    package func setMode(_ mode: ThemeMode) {
        guard mode != state else { return }
        defaults.set(mode.rawValue, forKey: Self.modeKey)
        setState(mode)
    }
}

/// Whether closing the window leaves Dish running behind the menu-bar item,
/// and whether the user has been told that it does.
package struct BackgroundPreferences: Equatable {
    package var runInBackground = true
    package var noticeShown = false

    package init(runInBackground: Bool = true, noticeShown: Bool = false) {
        self.runInBackground = runInBackground
        self.noticeShown = noticeShown
    }
}

@MainActor
package final class BackgroundPreferenceStore: StateSource<BackgroundPreferences> {
    static let runInBackgroundKey = "background_run_enabled"
    static let noticeShownKey = "background_notice_shown"

    private let defaults: UserDefaults

    package init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        super.init(initial: BackgroundPreferences(
            runInBackground: defaults.object(forKey: Self.runInBackgroundKey) as? Bool ?? true,
            noticeShown: defaults.bool(forKey: Self.noticeShownKey)
        ))
    }

    package func setRunInBackground(_ enabled: Bool) {
        guard enabled != state.runInBackground else { return }
        defaults.set(enabled, forKey: Self.runInBackgroundKey)
        updateState { var next = $0
            next.runInBackground = enabled
            return next
        }
    }

    package func setNoticeShown(_ shown: Bool) {
        guard shown != state.noticeShown else { return }
        defaults.set(shown, forKey: Self.noticeShownKey)
        updateState { var next = $0
            next.noticeShown = shown
            return next
        }
    }
}

/// How far Dish may hold the machine awake while it streams.
@MainActor
package final class KeepAwakePreferenceStore: StateSource<KeepAwakePreferences> {
    static let modeKey = "keep_awake_mode"
    static let timeoutMinutesKey = "keep_awake_timeout_minutes"
    static let displayKey = "keep_awake_display"

    private let defaults: UserDefaults

    package init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let storedTimeout = defaults.object(forKey: Self.timeoutMinutesKey) as? Int ?? KeepAwakeLimits.defaultTimeoutMinutes
        super.init(initial: KeepAwakePreferences(
            mode: KeepAwakeMode.fromStorage(defaults.string(forKey: Self.modeKey)),
            idleTimeoutMinutes: KeepAwakeLimits.clampTimeoutMinutes(storedTimeout),
            keepDisplayAwake: defaults.bool(forKey: Self.displayKey)
        ))
    }

    package func setMode(_ mode: KeepAwakeMode) {
        guard mode != state.mode else { return }
        defaults.set(mode.rawValue, forKey: Self.modeKey)
        updateState { var next = $0
            next.mode = mode
            return next
        }
    }

    package func setIdleTimeoutMinutes(_ minutes: Int) {
        let clamped = KeepAwakeLimits.clampTimeoutMinutes(minutes)
        guard clamped != state.idleTimeoutMinutes else { return }
        defaults.set(clamped, forKey: Self.timeoutMinutesKey)
        updateState { var next = $0
            next.idleTimeoutMinutes = clamped
            return next
        }
    }

    package func setKeepDisplayAwake(_ enabled: Bool) {
        guard enabled != state.keepDisplayAwake else { return }
        defaults.set(enabled, forKey: Self.displayKey)
        updateState { var next = $0
            next.keepDisplayAwake = enabled
            return next
        }
    }
}

/// The two reactive update preferences; the last-check stamp is imperative
/// bookkeeping that shares the store but not the published slice.
package struct UpdatePreferences: Equatable {
    package var checksEnabled = true
    /// The exact version the user muted; empty when none.
    package var skippedVersion = ""

    package init(checksEnabled: Bool = true, skippedVersion: String = "") {
        self.checksEnabled = checksEnabled
        self.skippedVersion = skippedVersion
    }
}

@MainActor
package final class UpdatePreferenceStore: StateSource<UpdatePreferences> {
    static let checksEnabledKey = "updates_check_enabled"
    static let skippedVersionKey = "updates_skipped_version"
    static let lastCheckKey = "updates_last_check_utc_ms"

    private let defaults: UserDefaults

    package init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        super.init(initial: UpdatePreferences(
            checksEnabled: defaults.object(forKey: Self.checksEnabledKey) as? Bool ?? true,
            skippedVersion: defaults.string(forKey: Self.skippedVersionKey) ?? ""
        ))
    }

    package func setChecksEnabled(_ enabled: Bool) {
        guard enabled != state.checksEnabled else { return }
        defaults.set(enabled, forKey: Self.checksEnabledKey)
        updateState { var next = $0
            next.checksEnabled = enabled
            return next
        }
    }

    package func setSkippedVersion(_ version: String) {
        guard version != state.skippedVersion else { return }
        defaults.set(version, forKey: Self.skippedVersionKey)
        updateState { var next = $0
            next.skippedVersion = version
            return next
        }
    }

    /// Milliseconds since the Unix epoch of the last completed check; 0
    /// when none ever completed.
    package var lastCheckMs: Int64 {
        Int64(defaults.object(forKey: Self.lastCheckKey) as? Int ?? 0)
    }

    package func setLastCheckMs(_ ms: Int64) {
        defaults.set(Int(ms), forKey: Self.lastCheckKey)
    }
}

/// Each pad's dead zones under the desktops' keys: one `deadzone:<slotId>`
/// entry per pad tuned, in their `{"s":…,"t":…}` shape. A pad never tuned
/// reads the defaults, and a value that does not read is nothing stored.
@MainActor
package final class DeadzonePreferenceStore: StateSource<[String: DeadzoneSetting]> {
    static let keyPrefix = "deadzone:"

    private let defaults: UserDefaults

    package init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        super.init(initial: Self.read(defaults))
    }

    package func zones(for slotId: String) -> DeadzoneSetting {
        state[slotId] ?? .defaults
    }

    package func setZones(_ zones: DeadzoneSetting, for slotId: String) {
        guard state[slotId] != zones else { return }
        defaults.set(zones.storedJson, forKey: Self.keyPrefix + slotId)
        updateState { var next = $0
            next[slotId] = zones
            return next
        }
    }

    package func reset(_ slotId: String) {
        defaults.removeObject(forKey: Self.keyPrefix + slotId)
        updateState { var next = $0
            next.removeValue(forKey: slotId)
            return next
        }
    }

    private static func read(_ defaults: UserDefaults) -> [String: DeadzoneSetting] {
        let stored = defaults.dictionaryRepresentation().filter { $0.key.hasPrefix(keyPrefix) }
        var all: [String: DeadzoneSetting] = [:]
        for (key, value) in stored {
            let slotId = String(key.dropFirst(keyPrefix.count))
            all[slotId] = DeadzoneSetting(storedJson: value as? String)
        }
        return all
    }
}

/// Each model's input path under the fleet's `usb_path_choices` key: one
/// dictionary of "vvvv:pppp" to "standard" or "direct", the desktops'
/// `UsbPathPreferenceStore` shape. A value that does not read (one a newer
/// build wrote) is no choice, so a downgrade never guesses.
@MainActor
package final class UsbPathChoiceStore: StateSource<[String: InputSource]> {
    static let choicesKey = "usb_path_choices"

    private let defaults: UserDefaults

    package init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        super.init(initial: Self.read(defaults))
    }

    package func choice(vendorId: UInt16, productId: UInt16) -> InputSource? {
        state[usbPathKey(vendorId: vendorId, productId: productId)]
    }

    package func setChoice(_ source: InputSource, vendorId: UInt16, productId: UInt16) {
        let key = usbPathKey(vendorId: vendorId, productId: productId)
        guard state[key] != source else { return }
        var next = state
        next[key] = source
        defaults.set(next.mapValues(\.rawValue), forKey: Self.choicesKey)
        setState(next)
    }

    private static func read(_ defaults: UserDefaults) -> [String: InputSource] {
        let stored = defaults.dictionary(forKey: choicesKey) ?? [:]
        return stored.compactMapValues { InputSource.fromStorage($0 as? String) }
    }
}

/// Each generic pad model's remap under the fleet's `joystick_remaps` key:
/// one dictionary of "vvvv:pppp" to the desktops' `JoystickRemapStore`
/// fields (`lsx`, `btn`, `hat`, …, with the entry's own key as `vk`). A
/// field that does not read keeps its default, and a value that is not a
/// dictionary is no remap, so a newer build's entry never breaks this one.
@MainActor
package final class JoystickRemapStore: StateSource<[String: JoystickRemap]> {
    static let remapsKey = "joystick_remaps"

    private let defaults: UserDefaults

    package init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        super.init(initial: Self.read(defaults))
    }

    package func remap(vendorId: UInt16, productId: UInt16) -> JoystickRemap? {
        state[usbPathKey(vendorId: vendorId, productId: productId)]
    }

    package func setRemap(_ remap: JoystickRemap, vendorId: UInt16, productId: UInt16) {
        let key = usbPathKey(vendorId: vendorId, productId: productId)
        guard state[key] != remap else { return }
        var next = state
        next[key] = remap
        write(next)
    }

    package func clearRemap(vendorId: UInt16, productId: UInt16) {
        let key = usbPathKey(vendorId: vendorId, productId: productId)
        guard state[key] != nil else { return }
        var next = state
        next.removeValue(forKey: key)
        write(next)
    }

    private func write(_ remaps: [String: JoystickRemap]) {
        let stored = Dictionary(uniqueKeysWithValues: remaps.map { key, remap in (key, Self.entry(key, remap)) })
        defaults.set(stored, forKey: Self.remapsKey)
        setState(remaps)
    }

    private static func entry(_ key: String, _ remap: JoystickRemap) -> [String: Any] {
        remapFields(remap).merging([RemapField.key: key]) { field, _ in field }
    }

    private static func read(_ defaults: UserDefaults) -> [String: JoystickRemap] {
        let stored = defaults.dictionary(forKey: remapsKey) ?? [:]
        return stored.compactMapValues { ($0 as? [String: Any]).map(remap(fields:)) }
    }
}

/// The first-run flags: whether the welcome was skipped or finished (the
/// desktops' key), and whether the scan that raises macOS's Local Network
/// prompt has run once after being explained (Android's key). Plain reads
/// over the defaults, so the window and the engine read one truth.
package struct OnboardingPreferenceStore {
    static let welcomeCompletedKey = "onboarding_welcome_completed"
    static let localNetworkPrimedKey = "local_network_primed"

    private let defaults: UserDefaults

    package init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    package var welcomeCompleted: Bool {
        defaults.bool(forKey: Self.welcomeCompletedKey)
    }

    package var localNetworkPrimed: Bool {
        defaults.bool(forKey: Self.localNetworkPrimedKey)
    }

    package func markWelcomeComplete() {
        defaults.set(true, forKey: Self.welcomeCompletedKey)
    }

    package func markLocalNetworkPrimed() {
        defaults.set(true, forKey: Self.localNetworkPrimedKey)
    }

    /// The welcome comes back on the next launch, as the siblings' tests reset it.
    package func resetWelcome() {
        defaults.removeObject(forKey: Self.welcomeCompletedKey)
    }
}

/// A pad's standing binding to a satellite, as kept across restarts: the
/// satellite's remembered id (its machine id) and the type the user picked,
/// nil for the pad's own. The pad's switches live under their own keys.
struct RememberedSatelliteBinding: Equatable, Codable {
    var slotId: String
    var satelliteId: String
    var emulatedType: Int?
}

/// The satellite bindings under `wifi_binding_list`, one record per pad.
/// Plain reads over the defaults, so every reader sees one truth; a value
/// that does not read is nothing stored.
struct BindingMemoryStore {
    static let bindingsKey = "wifi_binding_list"

    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func bindings() -> [RememberedSatelliteBinding] {
        guard let raw = defaults.data(forKey: Self.bindingsKey) else { return [] }
        return (try? JSONDecoder().decode([RememberedSatelliteBinding].self, from: raw)) ?? []
    }

    /// The pad's record, replacing whatever it had.
    func remember(_ binding: RememberedSatelliteBinding) {
        write(bindings().filter { $0.slotId != binding.slotId } + [binding])
    }

    func forget(slotId: String) {
        write(bindings().filter { $0.slotId != slotId })
    }

    func forgetSatellite(_ satelliteId: String) {
        write(bindings().filter { $0.satelliteId != satelliteId })
    }

    private func write(_ bindings: [RememberedSatelliteBinding]) {
        defaults.set(try? JSONEncoder().encode(bindings), forKey: Self.bindingsKey)
    }
}
