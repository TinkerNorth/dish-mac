// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// Folds a slot's motion facts down to the one state the gyro chip shows.
// The most blocking reason wins, so the user sees a single actionable
// explanation rather than a pile of overlapping warnings.

import Foundation

/// Declaration order is the precedence order.
public enum MotionIndicatorState: Equatable, Sendable {
    /// No gyro hardware.
    case unavailable
    /// The user turned motion off.
    case userDisabled
    /// Not on a live link that carries motion.
    case notForwarded
    /// The satellite sinks motion only for the types it has a backend for.
    case noHostSink
    /// The host has a sink for the type but its motion backend is unhealthy.
    case backendBroken
    /// Wired, live, and the host confirms the sink and the backend.
    case forwarding
}

public struct MotionIndicatorInputs: Equatable, Sendable {
    public var hasGyro: Bool
    public var userEnabled: Bool
    public var carriesOnConnection: Bool
    public var hostHasSinkForType: Bool
    /// Only consulted once `hostHasSinkForType` holds.
    public var backendOk: Bool

    public init(hasGyro: Bool, userEnabled: Bool, carriesOnConnection: Bool, hostHasSinkForType: Bool, backendOk: Bool) {
        self.hasGyro = hasGyro
        self.userEnabled = userEnabled
        self.carriesOnConnection = carriesOnConnection
        self.hostHasSinkForType = hostHasSinkForType
        self.backendOk = backendOk
    }
}

public func motionIndicatorFor(_ inputs: MotionIndicatorInputs) -> MotionIndicatorState {
    if !inputs.hasGyro { return .unavailable }
    if !inputs.userEnabled { return .userDisabled }
    if !inputs.carriesOnConnection { return .notForwarded }
    if !inputs.hostHasSinkForType { return .noHostSink }
    if !inputs.backendOk { return .backendBroken }
    return .forwarding
}
