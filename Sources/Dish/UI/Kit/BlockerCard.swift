// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import SwiftUI

struct BlockerCardState: Equatable {
    let title: String
    let message: String
    /// The dot's tone: an error for a lost host, a warning for an unplugged pad.
    let tone: Color
    let startOver: String
    let exit: String
}

/// What stops a walk, in the page and not over it: the reason under its
/// dot, and the two ways on, starting over or leaving.
struct BlockerCard: View {
    let state: BlockerCardState
    let startOver: () -> Void
    let exit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DishSpace.s5) {
            HStack(alignment: .top, spacing: DishSpace.s5) {
                StatusDot(color: state.tone)
                    .padding(.top, DishSpace.s2)
                VStack(alignment: .leading, spacing: DishSpace.s2) {
                    Text(state.title)
                        .font(DishFont.title)
                        .foregroundColor(DishTheme.onSurface)
                    Text(state.message)
                        .font(DishFont.detail)
                        .foregroundColor(DishTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: DishSpace.s4) {
                Spacer()
                Button(state.exit, action: exit)
                    .buttonStyle(DishOutlinedButtonStyle())
                Button(state.startOver, action: startOver)
                    .buttonStyle(DishOutlinedButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(DishSpace.s8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DishTheme.surface)
        .overlay(RoundedRectangle(cornerRadius: DishSize.cardRadius).stroke(state.tone, lineWidth: DishSize.hairline))
        .clipShape(RoundedRectangle(cornerRadius: DishSize.cardRadius))
    }
}
