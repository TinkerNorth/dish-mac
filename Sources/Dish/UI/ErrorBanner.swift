// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import SwiftUI

/// Inline error strip that sits in-window instead of a modal alert. Matches
/// the `ErrorBanner` widget in `dish-linux` and the `colorError` token used
/// across the Dish design system (#E74C3C).
struct ErrorBanner: View {

    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(DishTheme.error)
            Text(message)
                .font(.system(size: 12))
                .foregroundColor(DishTheme.onSurface)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(DishTheme.muted)
                    .padding(4)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(DishTheme.error.opacity(0.12))
        .overlay(
            RoundedRectangle(cornerRadius: 6).stroke(DishTheme.error, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
