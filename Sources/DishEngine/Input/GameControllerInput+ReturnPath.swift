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

    /// The pad's own `GCDeviceBattery` is read here, where the framework's
    /// reads are cheap; the Mac's is a blocking IOKit snapshot, so it is
    /// read on `batteryWorkQueue` and the two meet back on the main actor.
    func emitBattery(deviceId: String, controller: GCController, force: Bool) {
        let own = controller.battery.flatMap { Self.controllerBattery(level: $0.batteryLevel, state: $0.batteryState) }
        readHostBattery { [weak self] host in self?.forwardBattery(deviceId: deviceId, own: own, host: host, force: force) }
    }

    /// `deliver` runs on the main actor with the Mac's battery.
    func readHostBattery(_ deliver: @escaping @MainActor @Sendable (PadBattery) -> Void) {
        let read = hostBattery
        batteryWorkQueue.async {
            let host = read()
            Task { @MainActor in deliver(host) }
        }
    }

    /// The card shows the pad's own reading, or the Mac's for a pad that
    /// reports none; the wire carries the lower of the two. The 30 s timer
    /// (`force`) always sends, since MSG_BATTERY is a heartbeat and a lost
    /// datagram heals on the next tick; the state watch sends only when the
    /// status on the wire moved, the protocol's charging-transition trigger.
    func forwardBattery(deviceId: String, own: PadBattery?, host: PadBattery, force: Bool) {
        showBattery(batteryReading(own ?? host), onSlot: deviceId)
        let sent = lowestBattery(pad: own, host: host)
        let statusMoved = lastBatteryStatusRaw[deviceId] != sent.status.rawValue
        guard force || statusMoved else { return }
        lastBatteryStatusRaw[deviceId] = sent.status.rawValue
        processor.publishBattery(deviceId: deviceId, level: sent.level, statusRaw: sent.status.rawValue)
    }

    /// An unchanged reading is not written back, so the slots do not republish.
    func showBattery(_ reading: BatteryReading, onSlot slotId: String) {
        guard let index = slots.firstIndex(where: { $0.id == slotId }), slots[index].battery != reading else { return }
        slots[index].battery = reading
    }

    /// A controller's own battery for the wire, `level` in 0...1: none when
    /// the level reads unknown (a wired pad, or one that has not said yet),
    /// so the Mac's stands in.
    nonisolated static func controllerBattery(level: Float, state: GCDeviceBattery.State) -> PadBattery? {
        guard level >= 0 else { return nil }
        let percent: UInt8 = level > 1 ? 100 : UInt8(clamping: Int((level * 100.0).rounded()))
        return PadBattery(level: percent, status: batteryStatus(state))
    }

    nonisolated static func batteryStatus(_ state: GCDeviceBattery.State) -> BatteryStatus {
        switch state {
        case .unknown: .unknown
        case .discharging: .discharging
        case .charging: .charging
        case .full: .full
        @unknown default: .unknown
        }
    }
}
