// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import CoreHaptics
import Foundation
import GameController

/// Return-path + battery surfaces of `GameControllerInput`, split out of
/// `GameControllerInput.swift` to keep each file under the lint length budget.
/// These are all driven *into* the controller (light bar, rumble) or polled
/// from it (battery), as opposed to the input-forwarding hot path that stays
/// in the primary file. Behaviour is unchanged — this is purely an extension.
extension GameControllerInput {

    // MARK: - Lightbar (return path)

    /// Apply a host-game-driven light bar colour to the physical controller.
    /// Called from the `SatelliteClient` receive thread via the AppModel
    /// lightbar handler. No-op on controllers without a light (Xbox pads);
    /// the gate on `FeatureSettings.lightbarMode` happens upstream in
    /// `AppModel` so this method stays a pure "apply" with no policy.
    ///
    /// The actual `GCColor` write is serialised + coalesced through
    /// `lightbarApplier` rather than a fresh per-packet `Task`.
    func applyLightbar(deviceId: String, r: UInt8, g: UInt8, b: UInt8) {
        lightbarApplier.submit(
            deviceId: deviceId,
            value: LightbarColor(r: r, g: g, b: b)
        )
    }

    // MARK: - Rumble actuation (return path)

    /// Drive the physical controller's haptics. Called from the
    /// `SatelliteClient` receive thread (via the AppModel rumble handler).
    /// Most of the heavy lifting is in `RumbleActuator`; the apply closure
    /// resolves `deviceId → GCController` and gates on whether the pad
    /// actually exposes haptics (returns `nil` on MFi pads without haptics).
    ///
    /// The actuation is serialised + coalesced through `rumbleApplier` rather
    /// than a fresh per-packet `Task`, so a 60 Hz rumble stream collapses to
    /// one apply of the newest command and ordering is preserved.
    ///
    /// Vibration only — the light bar is a separate return path (see
    /// `applyLightbar`).
    func applyRumble(
        deviceId: String,
        strongMagnitude: UInt16,
        weakMagnitude: UInt16,
        durationMs: UInt16
    ) {
        rumbleApplier.submit(
            deviceId: deviceId,
            value: RumbleCommand(
                strong: strongMagnitude,
                weak: weakMagnitude,
                durationMs: durationMs
            )
        )
    }

    // MARK: - Battery

    /// Spin up the per-device battery timers. The 30 s timer is the steady
    /// wire cadence (fires once after `kBatteryFirstReportDelaySec`, then
    /// every `kBatteryPollIntervalSec`). The faster state-watch timer catches
    /// charging-state transitions between the 30 s ticks. Both closures hold a
    /// weak `controller` so they tolerate the pad going away between ticks
    /// (they no-op until `detach` cancels them).
    func startBatteryTimer(deviceId: String, controller: GCController) {
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
