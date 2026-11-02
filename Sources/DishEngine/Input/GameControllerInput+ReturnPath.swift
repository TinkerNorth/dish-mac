// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import CoreHaptics
import DishCore
import Foundation
import GameController

/// The return paths (light bar, rumble) and the battery poll of
/// `GameControllerInput`.
extension GameControllerInput {

    // MARK: - Return paths

    /// The return paths find a slot's controller by its id: filed here for
    /// the main actor's own reads, and on the feedback queue for its actuators.
    func fileController(_ controller: GCController?, for id: String) {
        controllersById[id] = controller
        padActuators.file(controller, for: id)
    }

    /// Each command lands on the pad's record, and the feedback queue applies
    /// the newest of each kind. The switches' gates sit upstream; a pad
    /// without the hardware ignores the command there.
    func applyLightbar(deviceId: String, r: UInt8, g: UInt8, b: UInt8) {
        feedback.pad(for: deviceId).post(lightbar: LightbarCommand(controllerIndex: 0, r: r, g: g, b: b))
    }

    func applyRumble(deviceId: String, strongMagnitude: UInt16, weakMagnitude: UInt16, durationMs: UInt16) {
        let command = RumbleCommand(
            controllerIndex: 0,
            strongMagnitude: strongMagnitude,
            weakMagnitude: weakMagnitude,
            durationMs: durationMs
        )
        feedback.pad(for: deviceId).post(rumble: command)
    }

    func applyTriggerEffects(deviceId: String, command: TriggerEffectsCommand) {
        feedback.pad(for: deviceId).post(triggerEffects: command)
    }

    func applyPlayerLeds(deviceId: String, player: Int) {
        feedback.pad(for: deviceId).post(player: player)
    }

    /// One decoded effect onto one trigger, each shape through the framework
    /// call that renders it.
    nonisolated static func play(_ effect: DualSenseTriggerEffect, on trigger: GCDualSenseAdaptiveTrigger) {
        switch effect {
        case .off:
            trigger.setModeOff()
        case let .feedback(startPosition, strength):
            trigger.setModeFeedbackWithStartPosition(startPosition, resistiveStrength: strength)
        case let .positionalFeedback(strengths):
            trigger.setModeFeedback(resistiveStrengths: positionalStrengths(strengths))
        case let .weapon(startPosition, endPosition, strength):
            trigger.setModeWeaponWithStartPosition(startPosition, endPosition: endPosition, resistiveStrength: strength)
        case let .vibration(startPosition, amplitude, frequency):
            trigger.setModeVibrationWithStartPosition(startPosition, amplitude: amplitude, frequency: frequency)
        case let .positionalVibration(amplitudes, frequency):
            trigger.setModeVibration(amplitudes: positionalAmplitudes(amplitudes), frequency: frequency)
        }
    }

    /// The framework's ten-zone struct from an array; a short array leaves
    /// the remaining zones at zero.
    nonisolated static func positionalStrengths(_ values: [Float]) -> GCDualSenseAdaptiveTrigger.PositionalResistiveStrengths {
        var out = GCDualSenseAdaptiveTrigger.PositionalResistiveStrengths()
        withUnsafeMutableBytes(of: &out.values) { raw in
            let zones = raw.bindMemory(to: Float.self)
            for (index, value) in values.prefix(zones.count).enumerated() {
                zones[index] = value
            }
        }
        return out
    }

    nonisolated static func positionalAmplitudes(_ values: [Float]) -> GCDualSenseAdaptiveTrigger.PositionalAmplitudes {
        var out = GCDualSenseAdaptiveTrigger.PositionalAmplitudes()
        withUnsafeMutableBytes(of: &out.values) { raw in
            let zones = raw.bindMemory(to: Float.self)
            for (index, value) in values.prefix(zones.count).enumerated() {
                zones[index] = value
            }
        }
        return out
    }

    /// Players one to four light the framework's four patterns; anything
    /// else clears them.
    nonisolated static func playerIndex(for player: Int) -> GCControllerPlayerIndex {
        switch player {
        case 1: .index1
        case 2: .index2
        case 3: .index3
        case 4: .index4
        default: .indexUnset
        }
    }

    // MARK: - Battery

    /// Spin up the per-device battery timers. The 30 s timer is the steady
    /// wire cadence (fires once after `kBatteryFirstReportDelaySec`, then
    /// every `kBatteryPollIntervalSec`). The faster state-watch timer catches
    /// charging-state transitions between the 30 s ticks. Both closures hold a
    /// weak `controller` so they tolerate the pad going away between ticks
    /// (they no-op until `detach` cancels them).
    func startBatteryTimer(deviceId: String, controller: GCController) {
        cancelBatteryTimers(deviceId)
        guard paths.showsInputSlot(deviceId) else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        let delay: DispatchTime = .now() + .seconds(kBatteryFirstReportDelaySec)
        timer.schedule(deadline: delay, repeating: .seconds(kBatteryPollIntervalSec))
        timer.setEventHandler { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.emitBattery(deviceId: deviceId, controller: controller, force: true)
        }
        timer.resume()
        batteryTimers[deviceId] = timer

        // Charging-state watch. Offset its first fire past the 30 s timer's
        // first sample so the steady cadence sets `lastBatteryStatusRaw`
        // before the watch starts comparing against it.
        let watch = DispatchSource.makeTimerSource(queue: .main)
        watch.schedule(
            deadline: .now() + .seconds(kBatteryFirstReportDelaySec + kBatteryStateWatchIntervalSec),
            repeating: .seconds(kBatteryStateWatchIntervalSec)
        )
        watch.setEventHandler { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.emitBattery(deviceId: deviceId, controller: controller, force: false)
        }
        watch.resume()
        batteryStateTimers[deviceId] = watch
    }

    func cancelBatteryTimers(_ deviceId: String) {
        batteryTimers.removeValue(forKey: deviceId)?.cancel()
        batteryStateTimers.removeValue(forKey: deviceId)?.cancel()
    }

    /// Resolve the battery reading for a controller and forward it. A pad has
    /// a *usable* reading when it exposes a `GCDeviceBattery` AND that battery
    /// reports a non-negative level (a wireless pad). When it doesn't — a
    /// wired/USB pad, or one whose level reads unknown — we fall back to the
    /// host Mac's battery so the satellite still shows something honest.
    ///
    /// `force == true` (the 30 s timer) always forwards — MSG_BATTERY is a
    /// fixed 30 s heartbeat so an unchanged value still has to reach the wire,
    /// and a dropped UDP packet self-heals on the next tick. `force == false`
    /// (the faster state-watch timer) forwards ONLY when the charging state
    /// changed from the last forwarded value — the protocol's "report on every
    /// charging-state transition" trigger, without spamming the wire.
    ///
    /// The host-fallback path needs a synchronous IOKit call, so the resolve
    /// runs on `batteryWorkQueue`; the controller's own `GCDeviceBattery`
    /// reads are cheap and stay on the main actor.
    func emitBattery(deviceId: String, controller: GCController, force: Bool) {
        if let battery = controller.battery, battery.batteryLevel >= 0 {
            // Controller's own battery — cheap reads, resolve inline.
            forwardBattery(
                deviceId: deviceId,
                resolved: Self.resolveControllerBattery(battery),
                force: force
            )
        } else {
            // No usable controller battery — report the host Mac instead. The
            // IOKit snapshot is blocking, so it runs off the main thread; the
            // forward hops back to the main actor. `self` is rebound to a
            // `let` so the nested `Task` doesn't reference the closure's
            // captured `var self` (forbidden in Swift 5.9 concurrent code).
            batteryWorkQueue.async { [weak self] in
                guard let self else { return }
                let resolved = Self.resolveHostBattery(
                    HostBattery.reading(from: HostBattery.snapshot())
                )
                Task { @MainActor in
                    self.forwardBattery(deviceId: deviceId, resolved: resolved, force: force)
                }
            }
        }
    }

    /// Update the slot-card pill and forward the resolved reading to the wire,
    /// applying the `force` / charging-state-transition gate. Runs on the main
    /// actor (it touches `slots` + `lastBatteryStatusRaw`).
    func forwardBattery(
        deviceId: String,
        resolved: BatteryResolution,
        force: Bool
    ) {
        let stateChanged = lastBatteryStatusRaw[deviceId] != resolved.statusRaw
        // State-watch tick with no transition → nothing to do. The 30 s timer
        // (force) still keeps the steady cadence.
        guard force || stateChanged else { return }

        // Update the slot card's battery pill.
        let reading = BatteryReading(
            level: resolved.level == 0xFF ? nil : Int(resolved.level),
            state: resolved.displayState
        )
        if let idx = slots.firstIndex(where: { $0.id == deviceId }) {
            slots[idx].battery = reading
        }

        lastBatteryStatusRaw[deviceId] = resolved.statusRaw
        processor.publishBattery(
            deviceId: deviceId,
            level: resolved.level,
            statusRaw: resolved.statusRaw
        )
    }

    /// Encode a controller's own `GCDeviceBattery` (a wireless pad reporting a
    /// usable percentage) for the wire. `batteryLevel` is Float in 0..1.
    static func resolveControllerBattery(
        _ battery: GCDeviceBattery
    ) -> BatteryResolution {
        let raw = battery.batteryLevel
        let level: UInt8 = raw > 1 ? 100 : UInt8(clamping: Int((raw * 100.0).rounded()))
        let statusRaw: UInt8 = switch battery.batteryState {
        case .unknown: 0
        case .discharging: 1
        case .charging: 2
        case .full: 3
        @unknown default: 0
        }
        let displayState: BatteryChargeState = switch battery.batteryState {
        case .discharging: .discharging
        case .charging: .charging
        case .full: .full
        default: .unknown
        }
        return BatteryResolution(level: level, statusRaw: statusRaw, displayState: displayState)
    }

    /// Adapt a host-Mac `HostBattery.WireReading` to the slot-card display
    /// state. `wired` (a desktop Mac) has no charge-state pill, so it shows as
    /// `.unknown` in the UI while still going out as `wired` on the wire.
    /// `nonisolated` — pure value mapping, run on `batteryWorkQueue` off main.
    nonisolated static func resolveHostBattery(
        _ host: HostBattery.WireReading
    ) -> BatteryResolution {
        let displayState: BatteryChargeState = switch host.status {
        case .discharging: .discharging
        case .charging: .charging
        case .full: .full
        case .wired, .unknown: .unknown
        }
        return BatteryResolution(
            level: host.level,
            statusRaw: host.status.rawValue,
            displayState: displayState
        )
    }
}
