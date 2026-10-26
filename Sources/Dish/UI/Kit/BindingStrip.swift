// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import SwiftUI

/// One chip on the strip, and what a click on it asks for; a chip with no
/// action is a fact, not a switch.
struct StripChip<Action: Equatable>: Equatable, Identifiable {
    let id: String
    let text: String
    let look: CapabilityChipLook
    let help: String
    let action: Action?
}

/// The binding, printed under its row: what the pad carries there as chips,
/// the switches among them clickable, and the way into Configure binding.
/// Reading the binding without pushing a page is the strip's whole job.
struct BindingStrip<Action: Equatable>: View {
    let title: String
    let chips: [StripChip<Action>]
    let editTitle: String
    let editHelp: String
    let perform: (Action) -> Void
    let edit: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: DishSpace.s5) {
            Text(title)
                .textCase(.uppercase)
                .font(DishFont.mono)
                .foregroundColor(DishTheme.muted)
            FlowLayout(spacing: DishSpace.s2) {
                ForEach(chips) { chip in
                    chipView(chip)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(editTitle, action: edit)
                .buttonStyle(DishOutlinedButtonStyle())
                .help(editHelp)
                .accessibilityLabel(editHelp)
        }
    }

    @ViewBuilder
    private func chipView(_ chip: StripChip<Action>) -> some View {
        if let action = chip.action {
            Button {
                perform(action)
            } label: {
                CapabilityChip(text: chip.text, look: chip.look, help: chip.help)
            }
            .buttonStyle(.plain)
        } else {
            CapabilityChip(text: chip.text, look: chip.look, help: chip.help)
        }
    }
}
