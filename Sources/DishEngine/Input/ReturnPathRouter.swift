// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import Foundation

/// Routes the satellite's return paths (rumble, light bar) from a connection
/// to the controller bound to it. The gate decision is pure and runs on the
/// receive queue; the binding lookup and the actuation hop to the main actor.
@MainActor
final class ReturnPathRouter {
    private let input: GameControllerInput
    private let gate: ForwardingGate
    private let bindings: () -> [String: String]
    /// Connections already wired, pruned to the pool on every pool change so
    /// a forgotten satellite that comes back under the same id is wired again.
    private var wired: Set<String> = []

    init(input: GameControllerInput, gate: ForwardingGate, bindings: @escaping () -> [String: String]) {
        self.input = input
        self.gate = gate
        self.bindings = bindings
    }

    /// Wire every connection in `pool` once, and forget the ones that left.
    func wire(_ pool: [String: WifiConnection]) {
        wired.formIntersection(pool.keys)
        for (id, conn) in pool where !wired.contains(id) {
            wired.insert(id)
            conn.setRumbleHandler { [weak self] command in self?.rumbleArrived(from: id, command) }
            conn.setLightbarHandler { [weak self] command in self?.lightbarArrived(from: id, command) }
        }
    }

    /// Receive queue: drop when the Rumble switch is off, else hop.
    private nonisolated func rumbleArrived(from connectionId: String, _ command: RumbleCommand) {
        guard ReturnPathRouting.shouldVibrate(flags: gate.snapshot()) else { return }
        Task { @MainActor in self.applyRumble(from: connectionId, command) }
    }

    private nonisolated func lightbarArrived(from connectionId: String, _ command: LightbarCommand) {
        guard ReturnPathRouting.shouldApply(lightbar: command, flags: gate.snapshot()) else { return }
        Task { @MainActor in self.applyLightbar(from: connectionId, command) }
    }

    private func applyRumble(from connectionId: String, _ command: RumbleCommand) {
        guard let deviceId = boundDevice(of: connectionId) else { return }
        input.applyRumble(
            deviceId: deviceId,
            strongMagnitude: command.strongMagnitude,
            weakMagnitude: command.weakMagnitude,
            durationMs: command.durationMs
        )
    }

    private func applyLightbar(from connectionId: String, _ command: LightbarCommand) {
        guard let deviceId = boundDevice(of: connectionId) else { return }
        input.applyLightbar(deviceId: deviceId, r: command.r, g: command.g, b: command.b)
    }

    /// The slot bound to `connectionId`; slot ids are device ids.
    private func boundDevice(of connectionId: String) -> String? {
        bindings().first { $0.value == connectionId }?.key
    }
}
