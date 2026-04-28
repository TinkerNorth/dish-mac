// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import SwiftUI

/// One row in the controllers list. Shows the slot, its bound connection
/// (if any) and a Bind/Unbind control. Mirrors `row_controller.xml`.
struct SlotCard: View {

    @EnvironmentObject var model: AppModel
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

    // MARK: - Derived

    private var availableConnections: [ConnectionSummary] {
        // Offer every connection that isn't already bound to a different slot.
        model.connections.filter { $0.boundSlotId == nil || $0.boundSlotId == slot.id }
    }

    private var subtitle: String {
        switch slot.inputType {
        case .virtual: "Virtual • \(bindLabel)"
        case .physical: "Gamepad • \(bindLabel)"
        }
    }

    private var bindLabel: String {
        guard let s = slot.boundStatus else { return "unbound" }
        switch s.live {
        case .connected: return "→ \(s.label)"
        case .connecting: return "→ \(s.label) (connecting…)"
        case .idle: return "→ \(s.label) (offline)"
        }
    }

    private var dotColor: Color {
        guard let s = slot.boundStatus else { return DishTheme.muted }
        return dotColorFor(s)
    }

    private func dotColorFor(_ s: ConnectionSummary) -> Color {
        switch s.live {
        case .connected: DishTheme.success
        case .connecting: DishTheme.primary
        case .idle: DishTheme.muted
        }
    }
}
