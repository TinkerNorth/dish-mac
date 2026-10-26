// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import Foundation

/// How a satellite's feedback reaches a pad: the controller bridge in
/// production, recorders in tests.
struct SatelliteFeedbackActuators {
    var rumble: @MainActor (_ deviceId: String, _ command: RumbleCommand) -> Void
    var lightbar: @MainActor (_ deviceId: String, _ command: LightbarCommand) -> Void
    var triggerEffects: @MainActor (_ deviceId: String, _ command: TriggerEffectsCommand) -> Void
    var playerLeds: @MainActor (_ deviceId: String, _ command: PlayerLedsCommand) -> Void

    @MainActor
    static func live(_ input: GameControllerInput) -> SatelliteFeedbackActuators {
        SatelliteFeedbackActuators(
            rumble: { deviceId, command in
                input.applyRumble(
                    deviceId: deviceId,
                    strongMagnitude: command.strongMagnitude,
                    weakMagnitude: command.weakMagnitude,
                    durationMs: command.durationMs
                )
            },
            lightbar: { deviceId, command in input.applyLightbar(deviceId: deviceId, r: command.r, g: command.g, b: command.b) },
            triggerEffects: { deviceId, command in input.applyTriggerEffects(deviceId: deviceId, command: command) },
            playerLeds: { deviceId, command in input.applyPlayerLeds(deviceId: deviceId, player: command.playerNumber) }
        )
    }
}

/// Routes the satellite's return paths (rumble, light bar, trigger effects,
/// player LEDs) from a connection to the controller bound to the index each
/// command names, so a satellite carrying four pads rumbles the right one. The gate
/// decision is pure and runs on the receive queue against the routing table
/// (rumble is a per-controller switch, the light bar a global one); the
/// actuation hops to the main actor. The two feedback paths have no switch:
/// a pad only receives them when its descriptor claimed them.
@MainActor
final class ReturnPathRouter {
    private let actuators: SatelliteFeedbackActuators
    private let gate: ForwardingGate
    private let table: RoutingTable
    /// Connections already wired, pruned to the pool on every pool change so
    /// a forgotten satellite that comes back under the same id is wired again.
    private var wired: Set<String> = []

    init(actuators: SatelliteFeedbackActuators, gate: ForwardingGate, table: RoutingTable) {
        self.actuators = actuators
        self.gate = gate
        self.table = table
    }

    /// Wire every connection in `pool` once, and forget the ones that left.
    func wire(_ pool: [String: WifiConnection]) {
        wired.formIntersection(pool.keys)
        for (id, conn) in pool where !wired.contains(id) {
            wired.insert(id)
            conn.setRumbleHandler { [weak self] command in self?.rumbleArrived(from: id, command) }
            conn.setLightbarHandler { [weak self] command in self?.lightbarArrived(from: id, command) }
            conn.setTriggerEffectsHandler { [weak self] command in self?.triggerEffectsArrived(from: id, command) }
            conn.setPlayerLedsHandler { [weak self] command in self?.playerLedsArrived(from: id, command) }
        }
    }

    private nonisolated func triggerEffectsArrived(from connectionId: String, _ command: TriggerEffectsCommand) {
        Task { @MainActor in self.applyTriggerEffects(from: connectionId, command) }
    }

    private nonisolated func playerLedsArrived(from connectionId: String, _ command: PlayerLedsCommand) {
        Task { @MainActor in self.applyPlayerLeds(from: connectionId, command) }
    }

    private func applyTriggerEffects(from connectionId: String, _ command: TriggerEffectsCommand) {
        guard let deviceId = boundDevice(of: connectionId, command.controllerIndex) else { return }
        actuators.triggerEffects(deviceId, command)
    }

    private func applyPlayerLeds(from connectionId: String, _ command: PlayerLedsCommand) {
        guard let deviceId = boundDevice(of: connectionId, command.controllerIndex) else { return }
        actuators.playerLeds(deviceId, command)
    }

    /// Receive queue: drop when the bound controller's Rumble switch is off,
    /// else hop.
    private nonisolated func rumbleArrived(from connectionId: String, _ command: RumbleCommand) {
        let pad = SatellitePadKey(connectionId: connectionId, controllerIndex: Int(command.controllerIndex))
        guard let bound = table.boundSlot(of: pad), ReturnPathRouting.shouldVibrate(flags: bound.flags) else { return }
        Task { @MainActor in self.applyRumble(from: connectionId, command) }
    }

    private nonisolated func lightbarArrived(from connectionId: String, _ command: LightbarCommand) {
        guard ReturnPathRouting.shouldApply(lightbar: command, flags: gate.snapshot()) else { return }
        Task { @MainActor in self.applyLightbar(from: connectionId, command) }
    }

    private func applyRumble(from connectionId: String, _ command: RumbleCommand) {
        guard let deviceId = boundDevice(of: connectionId, command.controllerIndex) else { return }
        actuators.rumble(deviceId, command)
    }

    private func applyLightbar(from connectionId: String, _ command: LightbarCommand) {
        guard let deviceId = boundDevice(of: connectionId, command.controllerIndex) else { return }
        actuators.lightbar(deviceId, command)
    }

    /// The slot bound to the connection's controller index; slot ids are device ids.
    private func boundDevice(of connectionId: String, _ controllerIndex: UInt8) -> String? {
        table.boundSlot(of: SatellitePadKey(connectionId: connectionId, controllerIndex: Int(controllerIndex)))?.slotId
    }
}
