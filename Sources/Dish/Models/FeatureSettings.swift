// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Combine
import Foundation

/// How the controller light bar should behave while a slot is bound.
///
/// Mirrors the choice DS4Windows / DualSenseX expose ("lightbar from game"
/// vs "off"). Dish has no custom-colour picker yet — a forwarder reflects
/// what the host game sets, so the meaningful axis is just follow-vs-off.
enum LightbarMode: String, CaseIterable, Identifiable, Codable {
    /// Apply the colour the host game writes (forwarded via `MSG_LIGHTBAR`).
    case followGame
    /// Ignore `MSG_LIGHTBAR`; leave the controller's light bar untouched.
    case off

    var id: String {
        rawValue
    }

    var label: String {
        switch self {
        case .followGame: "Follow game"
        case .off: "Off"
        }
    }
}

/// User-facing on/off switches for each forwarded controller feature.
///
/// These gate whether dish *sends* (motion, touchpad) or *acts on* (rumble,
/// light bar) the corresponding data — they do not change what the controller
/// hardware reports. A feature being toggled off is a privacy / preference
/// choice (some players find gyro forwarding noisy, or don't want the LED
/// changing), not a capability statement. Whether the *hardware* supports a
/// feature is `ControllerCapabilities`, surfaced separately in the slot card.
///
/// Persisted to `UserDefaults` so the choice survives relaunch — the same
/// store `ConnectionStore` uses. MVVM: this is an `ObservableObject` the
/// `AppModel` owns and the `SettingsView` binds to.
@MainActor
final class FeatureSettings: ObservableObject {

    /// Forward gyro + accelerometer samples (`MSG_MOTION`). Default on —
    /// every competitor that supports motion forwards it by default; the
    /// toggle exists for players who don't want it.
    @Published var motionEnabled: Bool {
        didSet { defaults.set(motionEnabled, forKey: Keys.motion) }
    }

    /// Act on rumble notifications the host game sends back (`MSG_RUMBLE`).
    /// Default on. Off makes `applyRumble` a silent no-op.
    @Published var rumbleEnabled: Bool {
        didSet { defaults.set(rumbleEnabled, forKey: Keys.rumble) }
    }

    /// Forward DualSense / DualShock 4 touchpad samples (`MSG_TOUCHPAD`).
    /// Default on.
    @Published var touchpadEnabled: Bool {
        didSet { defaults.set(touchpadEnabled, forKey: Keys.touchpad) }
    }

    /// Light-bar behaviour. Default `.followGame`.
    @Published var lightbarMode: LightbarMode {
        didSet { defaults.set(lightbarMode.rawValue, forKey: Keys.lightbar) }
    }

    private let defaults: UserDefaults

    private enum Keys {
        static let motion = "feature_motion_enabled"
        static let rumble = "feature_rumble_enabled"
        static let touchpad = "feature_touchpad_enabled"
        static let lightbar = "feature_lightbar_mode"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // `object(forKey:)` is nil on first launch — fall back to the
        // documented default (everything on, light bar follows the game).
        self.motionEnabled = (defaults.object(forKey: Keys.motion) as? Bool) ?? true
        self.rumbleEnabled = (defaults.object(forKey: Keys.rumble) as? Bool) ?? true
        self.touchpadEnabled = (defaults.object(forKey: Keys.touchpad) as? Bool) ?? true
        if let raw = defaults.string(forKey: Keys.lightbar),
           let mode = LightbarMode(rawValue: raw)
        {
            self.lightbarMode = mode
        } else {
            self.lightbarMode = .followGame
        }
    }

    /// Plain-value snapshot for the thread-safe `ForwardingGate`. `lightbar`
    /// gates whether the host game's `MSG_LIGHTBAR` colour is applied.
    var flags: ForwardingFlags {
        ForwardingFlags(
            motion: motionEnabled,
            touchpad: touchpadEnabled,
            rumble: rumbleEnabled,
            lightbar: lightbarMode == .followGame
        )
    }
}

/// Plain-value snapshot of the forwarding toggles. `Sendable` so it can cross
/// from the main actor into `ForwardingGate` and be read on the hot path.
struct ForwardingFlags: Equatable {
    var motion = true
    var touchpad = true
    var rumble = true
    var lightbar = true
}

/// Thread-safe holder for the forwarding toggles.
///
/// The hot-path senders run on the GameController callback thread (motion,
/// touchpad) and the UDP receive thread (rumble, light bar) — they cannot
/// touch the `@MainActor`-isolated `FeatureSettings` directly. Instead
/// `AppModel` pushes a fresh `ForwardingFlags` snapshot here whenever the user
/// flips a switch, and the senders read it lock-protected. Same `os_unfair_lock`
/// pattern as `RoutingTable` / `ClientRef`.
final class ForwardingGate: @unchecked Sendable {

    private var lock = os_unfair_lock_s()
    private var flags = ForwardingFlags()

    func snapshot() -> ForwardingFlags {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return flags
    }

    func update(_ newFlags: ForwardingFlags) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        flags = newFlags
    }
}
