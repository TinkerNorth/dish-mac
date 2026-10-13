// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishEngine
import SwiftUI

/// One row in the controllers list: the slot, its detected hardware
/// capabilities, the bound connection, and a Bind or Unbind control.
struct SlotCard: View {

    @EnvironmentObject var model: AppModel
    @EnvironmentObject var settings: FeatureSettings
    let slot: ControllerSlot

    @State private var expanded = false

    private let words = L10n.app

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            titleRow
            capabilityRow
            if expanded, slot.boundConnectionId == nil {
                bindPicker
            }
        }
        .padding(12)
        .background(DishTheme.surface)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(DishTheme.cardStroke, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var bindable: [ConnectionSummary] {
        bindableConnections(for: slot, in: model.connections)
    }

    private var titleRow: some View {
        HStack(spacing: 10) {
            ZStack(alignment: .bottomTrailing) {
                BrandIcon(kind: .satellite, state: slotIconState(slot), size: 28)
                StatusDot(color: slotDotColor(slot))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(slot.name)
                    .font(DishFont.body)
                    .foregroundColor(DishTheme.onSurface)
                Text(slotSubtitle(slot))
                    .font(DishFont.caption)
                    .foregroundColor(DishTheme.muted)
            }
            Spacer()
            if slot.boundConnectionId != nil {
                Button(words.unbind) { model.unbind(slotId: slot.id) }
                    .buttonStyle(DishOutlinedButtonStyle())
            } else {
                Button(bindButtonTitle(expanded: expanded)) { expanded.toggle() }
                    .buttonStyle(DishOutlinedButtonStyle())
                    .disabled(bindable.isEmpty)
            }
        }
    }

    /// Chips for each hardware feature, plus the battery pill once the first
    /// reading lands.
    private var capabilityRow: some View {
        HStack(spacing: 6) {
            ForEach(capabilityChips(slot.capabilities, settings.flags), id: \.label) { chip in
                CapabilityChipView(chip: chip)
            }
            Spacer(minLength: 0)
            if let battery = slot.battery {
                BatteryPill(reading: battery)
            }
        }
    }

    private var bindPicker: some View {
        VStack(spacing: 4) {
            ForEach(bindable) { conn in
                Button {
                    model.bind(slotId: slot.id, connectionId: conn.id)
                    expanded = false
                } label: {
                    bindOption(conn)
                }
                .buttonStyle(.plain)
            }
            if bindable.isEmpty {
                Text(words.noConnectionsAddOne)
                    .font(DishFont.caption)
                    .foregroundColor(DishTheme.muted)
                    .padding(.vertical, 6)
            }
        }
    }

    private func bindOption(_ conn: ConnectionSummary) -> some View {
        HStack {
            ZStack(alignment: .bottomTrailing) {
                BrandIcon.satellite(for: conn.live, size: 22)
                StatusDot(color: linkDotColor(conn.live))
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(conn.label)
                    .font(DishFont.control)
                    .foregroundColor(DishTheme.onSurface)
                Text(conn.detail)
                    .font(DishFont.microRegular)
                    .foregroundColor(DishTheme.muted)
            }
            Spacer()
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(DishTheme.surfaceDim)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

/// One capability pill. Available and on fills; available and off outlines;
/// absent hardware outlines dashed, so "not available" never reads as "off".
/// The tooltip spells the state out as a second channel.
private struct CapabilityChipView: View {

    let chip: CapabilityChipModel

    var body: some View {
        Text(chip.label)
            .font(DishFont.micro)
            .foregroundColor(chip.on ? DishTheme.primary : DishTheme.muted)
            .opacity(chip.available ? 1.0 : 0.7)
            .padding(.vertical, 3)
            .padding(.horizontal, 7)
            .background(RoundedRectangle(cornerRadius: 5).fill(chip.on ? DishTheme.chipFill : Color.clear))
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(
                        chip.on ? Color.clear : DishTheme.outline,
                        style: StrokeStyle(lineWidth: 1, dash: chip.available ? [] : [3])
                    )
            )
            .help(chip.help)
    }
}

/// The battery pill: a glyph that steps with the level, a bolt while
/// charging, and the percentage.
private struct BatteryPill: View {

    let reading: BatteryReading

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: batterySymbol(reading))
                .font(DishFont.microRegular)
            Text(batteryLevelText(reading))
                .font(DishFont.micro)
        }
        .foregroundColor(batteryTint(reading))
        .help(batteryHelp(reading))
    }
}
