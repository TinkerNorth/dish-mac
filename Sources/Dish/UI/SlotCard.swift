// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import SwiftUI

/// One row in the controllers list. Shows the slot, its detected hardware
/// capabilities, the bound connection (if any) and a Bind/Unbind control.
/// Mirrors `row_controller.xml`.
struct SlotCard: View {

    @EnvironmentObject var model: AppModel
    @EnvironmentObject var settings: FeatureSettings
    let slot: ControllerSlot

    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                StatusDot(color: dotColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(slot.name)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(DishTheme.onSurface)
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundColor(DishTheme.muted)
                }
                Spacer()
                if slot.boundConnectionId != nil {
                    Button("Unbind") { model.unbind(slotId: slot.id) }
                        .buttonStyle(DishOutlinedButtonStyle())
                } else {
                    Button(expanded ? "Close" : "Bind") { expanded.toggle() }
                        .buttonStyle(DishOutlinedButtonStyle())
                        .disabled(availableConnections.isEmpty)
                }
            }

            capabilityRow

            if expanded, slot.boundConnectionId == nil {
                VStack(spacing: 4) {
                    ForEach(availableConnections) { conn in
                        Button {
                            model.bind(slotId: slot.id, connectionId: conn.id)
                            expanded = false
                        } label: {
                            HStack {
                                StatusDot(color: dotColorFor(conn))
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(conn.label)
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundColor(DishTheme.onSurface)
                                    Text(conn.detail)
                                        .font(.system(size: 10))
                                        .foregroundColor(DishTheme.muted)
                                }
                                Spacer()
                            }
                            .padding(.vertical, 6)
                            .padding(.horizontal, 8)
                            .background(DishTheme.surfaceDim)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                    }
                    if availableConnections.isEmpty {
                        Text("No connections — add one from Manage")
                            .font(.system(size: 11))
                            .foregroundColor(DishTheme.muted)
                            .padding(.vertical, 6)
                    }
                }
            }
        }
        .padding(12)
        .background(DishTheme.surface)
        .overlay(
            RoundedRectangle(cornerRadius: 8).stroke(DishTheme.cardStroke, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Capability row

    /// Chips for each hardware feature, plus a battery pill. A chip's colour
    /// means "the feature is on/off in Settings". This is the "gyro detected"
    /// feedback DS4Windows / Steam Input surface — the player can tell apart
    /// "my pad has no gyro" from "gyro is switched off".
    ///
    /// Motion is *always* shown: a controller with an IMU gets a "Gyro" chip
    /// (on/off by Settings), one without gets an explicit dashed "No gyro"
    /// chip. Touchpad/rumble/battery still only appear when present — but
    /// motion is the Task 1.1 surface and its absence must never be silent.
    @ViewBuilder
    private var capabilityRow: some View {
        let caps = slot.capabilities
        HStack(spacing: 6) {
            if caps.hasMotion {
                CapabilityChip(label: "Gyro", on: settings.motionEnabled, feature: "Motion")
            } else {
                CapabilityChip(label: "No gyro", on: false, feature: "Motion", available: false)
            }
            if caps.hasTouchpad {
                CapabilityChip(label: "Touchpad", on: settings.touchpadEnabled, feature: "Touchpad")
            }
            if caps.hasRumble {
                CapabilityChip(label: "Rumble", on: settings.rumbleEnabled, feature: "Rumble")
            }
            Spacer(minLength: 0)
            if caps.hasBattery, let battery = slot.battery {
                BatteryPill(reading: battery)
            }
        }
    }

    // MARK: - Derived

    private var availableConnections: [ConnectionSummary] {
        // Offer every connection that isn't already bound to a different slot.
        model.connections.filter { $0.boundSlotId == nil || $0.boundSlotId == slot.id }
    }

    private var subtitle: String {
        "Gamepad • \(bindLabel)"
    }

    private var bindLabel: String {
        guard let status = slot.boundStatus else { return "unbound" }
        switch status.live {
        case .connected: return "→ \(status.label)"
        case .connecting: return "→ \(status.label) (connecting…)"
        case .idle: return "→ \(status.label) (offline)"
        }
    }

    private var dotColor: Color {
        guard let status = slot.boundStatus else { return DishTheme.muted }
        return dotColorFor(status)
    }

    private func dotColorFor(_ status: ConnectionSummary) -> Color {
        switch status.live {
        case .connected: DishTheme.success
        case .connecting: DishTheme.primary
        case .idle: DishTheme.muted
        }
    }
}

/// A small pill for one controller capability. Three visually distinct states,
/// so the player can never confuse them:
///   • available + on  — full-colour fill ("detected, forwarding on")
///   • available + off — muted, solid outline ("detected, off in Settings")
///   • not available   — muted, *dashed* outline ("controller has no such hw")
/// The `.help` tooltip spells the state out in words as a second channel.
private struct CapabilityChip: View {

    let label: String
    let on: Bool
    /// Human name of the matching feature, for the tooltip.
    let feature: String
    /// False when the controller lacks the hardware entirely. Rendered with a
    /// dashed outline so "not available" never reads the same as "off".
    var available = true

    var body: some View {
        Text(label)
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(on ? DishTheme.primary : DishTheme.muted)
            .opacity(available ? 1.0 : 0.7)
            .padding(.vertical, 3)
            .padding(.horizontal, 7)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(on ? DishTheme.primary.opacity(0.14) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(
                        on ? Color.clear : DishTheme.outline,
                        style: StrokeStyle(lineWidth: 1, dash: available ? [] : [3])
                    )
            )
            .help(helpText)
    }

    private var helpText: String {
        if !available {
            return "\(feature) not available — this controller has no "
                + (feature == "Motion" ? "gyroscope or accelerometer." : "hardware for it.")
        }
        return on
            ? "\(feature) detected — forwarding to the host is on"
            : "\(feature) detected — turned off in Settings"
    }
}

/// Battery level pill shown when the controller reports a charge level. The
/// SF Symbol steps with the level; a bolt overlays while charging.
private struct BatteryPill: View {

    let reading: BatteryReading

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.system(size: 10))
            Text(levelText)
                .font(.system(size: 10, weight: .medium))
        }
        .foregroundColor(tint)
        .help(helpText)
    }

    private var charging: Bool {
        reading.state == .charging || reading.state == .full
    }

    private var symbol: String {
        if charging { return "battery.100.bolt" }
        switch reading.level ?? -1 {
        case 0 ..< 13: return "battery.0"
        case 13 ..< 38: return "battery.25"
        case 38 ..< 63: return "battery.50"
        case 63 ..< 88: return "battery.75"
        case 88 ... 100: return "battery.100"
        default: return "battery.50" // unknown level
        }
    }

    private var levelText: String {
        guard let level = reading.level else { return "—" }
        return "\(level)%"
    }

    private var tint: Color {
        if charging { return DishTheme.success }
        switch reading.level ?? 100 {
        case 0 ..< 15: return DishTheme.error
        case 15 ..< 30: return DishTheme.warning
        default: return DishTheme.muted
        }
    }

    private var helpText: String {
        let pct = reading.level.map { "\($0)%" } ?? "unknown level"
        switch reading.state {
        case .charging: return "Battery \(pct) — charging"
        case .full: return "Battery full"
        case .discharging: return "Battery \(pct)"
        case .unknown: return "Battery \(pct)"
        }
    }
}
