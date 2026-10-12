// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishEngine
import SwiftUI

/// The inline error strip that sits in the window instead of a modal alert.
struct ErrorBanner: View {

    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(DishTheme.error)
            Text(message)
                .font(DishFont.detail)
                .foregroundColor(DishTheme.onSurface)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(DishFont.closeGlyph)
                    .foregroundColor(DishTheme.muted)
                    .padding(4)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(DishTheme.errorFill)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(DishTheme.error, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
