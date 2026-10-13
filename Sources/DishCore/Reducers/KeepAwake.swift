// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// When Dish holds the machine awake, and how far. Pure: the inhibitor
// performs, this decides. The storage tokens are the fleet's, so a profile
// written by another Dish client reads the same here.

import Foundation

public enum KeepAwakeMode: String, CaseIterable, Equatable, Sendable {
    case off
    /// Streaming, and input seen inside the idle window.
    case whileControllerActive = "controller-active"
    /// Streaming, however long the pad has sat still.
    case whileConnected = "connected"

    /// Lenient: an unknown or empty key is the default, so a hand-edited or
    /// downgraded profile cannot leave the machine pinned awake.
    public static func fromStorage(_ key: String?) -> KeepAwakeMode {
        key.flatMap(KeepAwakeMode.init(rawValue:)) ?? .whileControllerActive
    }
}

/// How far the hold reaches. Display implies system: a lit screen on a
/// suspended machine is not a state any platform offers.
public enum KeepAwakeReach: Equatable, Sendable {
    case none
    case system
    case systemAndDisplay
}

public enum KeepAwakeLimits {
    public static let minTimeoutMinutes = 1
    public static let maxTimeoutMinutes = 180
    public static let defaultTimeoutMinutes = 5

    public static func clampTimeoutMinutes(_ minutes: Int) -> Int {
        min(max(minutes, minTimeoutMinutes), maxTimeoutMinutes)
    }
}

public struct KeepAwakePreferences: Equatable, Sendable {
    public var mode = KeepAwakeMode.whileControllerActive
    public var idleTimeoutMinutes = KeepAwakeLimits.defaultTimeoutMinutes
    /// Off by default: forwarding a pad needs the machine, not the panel.
    public var keepDisplayAwake = false

    public init(
        mode: KeepAwakeMode = .whileControllerActive,
        idleTimeoutMinutes: Int = KeepAwakeLimits.defaultTimeoutMinutes,
        keepDisplayAwake: Bool = false
    ) {
        self.mode = mode
        self.idleTimeoutMinutes = idleTimeoutMinutes
        self.keepDisplayAwake = keepDisplayAwake
    }
}

/// Whether input at `lastInputMs` is still inside the window at `nowMs`. A
/// non-positive timeout never expires, and a clock that steps backwards
/// reads as activity rather than as an expired window.
public func controllerActive(lastInputMs: Int64, nowMs: Int64, timeoutMs: Int64) -> Bool {
    if timeoutMs <= 0 { return true }
    if nowMs <= lastInputMs { return true }
    return nowMs - lastInputMs < timeoutMs
}

/// The one rule the inhibitor is driven from.
public func deriveKeepAwakeReach(_ prefs: KeepAwakePreferences, streamingSlotCount: Int, controllerActive: Bool) -> KeepAwakeReach {
    if prefs.mode == .off { return .none }
    if streamingSlotCount <= 0 { return .none }
    if prefs.mode == .whileControllerActive, !controllerActive { return .none }
    return prefs.keepDisplayAwake ? .systemAndDisplay : .system
}

/// What the wake controller acts on. `streamingSlotCount` rides along so a
/// count change that does not move the reach still reads as a distinct value.
public struct WakeState: Equatable, Sendable {
    public var reach: KeepAwakeReach
    public var streamingSlotCount: Int

    public init(reach: KeepAwakeReach = .none, streamingSlotCount: Int = 0) {
        self.reach = reach
        self.streamingSlotCount = streamingSlotCount
    }
}

public func deriveWakeState(streamingSlotCount: Int, controllerActive: Bool, prefs: KeepAwakePreferences) -> WakeState {
    WakeState(
        reach: deriveKeepAwakeReach(prefs, streamingSlotCount: streamingSlotCount, controllerActive: controllerActive),
        streamingSlotCount: streamingSlotCount
    )
}
