// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import SwiftUI

/// What the Connections and Moonlight hosts rows share.
enum ConnectionRowParts {
    /// The glyph a connection row leads with.
    static let glyphSize: CGFloat = 28
}

/// A row's chips, in the order the mapper put them.
struct ChipRow: View {
    let chips: [ChipState]

    var body: some View {
        HStack(spacing: DishSpace.s3) {
            ForEach(chips.indices, id: \.self) { index in
                StateChip(text: chips[index].text, color: chips[index].color, help: chips[index].help)
            }
        }
    }
}

/// The destructive action sits behind ⋯ so it is never the mis-click next
/// to the row's primary button.
struct RowMenu: View {
    let state: RowMenuState
    let forget: () -> Void

    var body: some View {
        Menu {
            Button(state.forget, role: .destructive, action: forget)
        } label: {
            Image(systemName: "ellipsis")
                .font(DishFont.icon)
                .foregroundColor(DishTheme.primary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(state.label)
        .help(state.label)
    }
}

extension View {
    /// The one modal a Connections page raises: Forget, with what it drops.
    func forgetConfirmation(_ state: ForgetDialogState, confirm: @escaping () -> Void, cancel: @escaping () -> Void) -> some View {
        modifier(ForgetConfirmation(state: state, confirm: confirm, cancel: cancel))
    }
}

private struct ForgetConfirmation: ViewModifier {
    let state: ForgetDialogState
    let confirm: () -> Void
    let cancel: () -> Void

    private var presented: Binding<Bool> {
        Binding(get: shown, set: dismissed)
    }

    func body(content: Content) -> some View {
        content.confirmationDialog(state.title, isPresented: presented, titleVisibility: .visible) {
            Button(state.confirm, role: .destructive, action: confirm)
            Button(state.cancel, role: .cancel, action: cancel)
        } message: {
            Text(state.message)
        }
    }

    private func shown() -> Bool {
        state.shown
    }

    /// Escape and a click outside close the dialog without either button.
    private func dismissed(_ stillShown: Bool) {
        if !stillShown { cancel() }
    }
}
