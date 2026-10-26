// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import SwiftUI

/// The card a satellite's row opens into while it pairs, both paths at once
/// as on the desktops: the satellite's PIN typed into four cells over one
/// hidden digit field (a paste lands whole), and, while an operator request
/// is filed, this Mac's PIN to type on the satellite with where the request
/// stands. It reads only its state and calls only its closures.
struct PairingCard: View {
    let state: PairingCardState
    @Binding var pin: String
    let pair: () -> Void
    let cancel: () -> Void
    let newCode: () -> Void

    @FocusState private var pinFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: DishSpace.s6) {
            Text(state.pinPrompt)
                .font(DishFont.detail)
                .foregroundColor(DishTheme.muted)
            typedPin
            if let pinError = state.pinError {
                Text(pinError)
                    .font(DishFont.caption)
                    .foregroundColor(DishTheme.error)
            }
            if let request = state.request {
                PairingRequestSection(request: request, newCode: newCode)
            }
            buttons
        }
        .padding(DishSpace.s6)
        .background(DishTheme.surfaceDim)
        .clipShape(RoundedRectangle(cornerRadius: DishSize.cardRadius))
        .onAppear(perform: focusPin)
    }

    /// The field is laid over the cells and draws nothing of its own: it
    /// owns the clicks, the focus, the typing and the paste, and the cells
    /// render what it holds. Its ink is clear rather than its opacity zero,
    /// because a view at zero opacity takes no clicks, and its label is
    /// empty, because a titled field draws its title as a placeholder.
    private var typedPin: some View {
        ZStack {
            PinCells(digits: state.typedCells, stroke: state.cellStroke, ink: DishTheme.onSurface)
            TextField(text: $pin, prompt: nil) { EmptyView() }
                .textFieldStyle(.plain)
                .font(DishFont.pinDigit)
                .foregroundColor(.clear)
                .focused($pinFocused)
                .disabled(!state.fieldEnabled)
                .onSubmit(pair)
                .accessibilityLabel(state.pinFieldLabel)
                .frame(width: PinCells.width(of: state.typedCells.count), height: PinCells.cellHeight)
        }
        .frame(maxWidth: .infinity)
    }

    private var buttons: some View {
        HStack {
            Spacer()
            Button(state.cancelTitle, action: cancel)
                .buttonStyle(DishOutlinedButtonStyle())
            Button(action: pair) {
                if state.showsPairSpinner {
                    HStack(spacing: DishSpace.s3) {
                        DishSpinner(size: DishSize.buttonSpinner)
                        Text(state.pairTitle)
                    }
                } else {
                    Text(state.pairTitle)
                }
            }
            .buttonStyle(DishOutlinedButtonStyle())
            .disabled(!state.pairEnabled)
        }
    }

    private func focusPin() {
        pinFocused = true
    }
}

/// The operator request's half of the card.
private struct PairingRequestSection: View {
    let request: PairingRequestState
    let newCode: () -> Void

    private static let barWidth: CGFloat = 60

    var body: some View {
        VStack(alignment: .leading, spacing: DishSpace.s5) {
            HStack(spacing: DishSpace.s4) {
                rule
                Text(request.orWord)
                    .font(DishFont.caption)
                    .foregroundColor(DishTheme.muted)
                rule
            }
            Text(request.approvePrompt)
                .font(DishFont.detail)
                .foregroundColor(DishTheme.muted)
            PinCells(digits: request.clientPinCells, stroke: DishTheme.outline, ink: DishTheme.primary)
                .frame(maxWidth: .infinity)
            status
        }
    }

    private var rule: some View {
        Rectangle()
            .fill(DishTheme.outline)
            .frame(height: DishSize.hairline)
    }

    private var status: some View {
        HStack(spacing: DishSpace.s5) {
            if request.showsProgress {
                DishBar(width: Self.barWidth)
            }
            Text(request.status)
                .font(DishFont.detail)
                .foregroundColor(request.statusColor)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let newCodeTitle = request.newCodeTitle {
                Button(newCodeTitle, action: newCode)
                    .buttonStyle(DishOutlinedButtonStyle())
            }
            if let hint = request.hint {
                Text(hint)
                    .font(DishFont.monoChip)
                    .foregroundColor(DishTheme.muted)
            }
        }
    }
}
