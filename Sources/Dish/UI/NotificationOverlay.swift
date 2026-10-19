// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishEngine
import SwiftUI

/// The toast strip at the bottom of the window. Reads the notification
/// queue and animates entries and exits with the brand fade and slide.
struct NotificationOverlay: View {

    @EnvironmentObject var center: DishNotificationCenter

    var body: some View {
        VStack(spacing: 8) {
            // Newest on top; the queue itself stays in insertion order.
            ForEach(center.state.reversed()) { notification in
                NotificationToast(notification: notification) {
                    center.dismiss(id: notification.id)
                }
                .transition(.asymmetric(
                    insertion: .move(edge: .bottom).combined(with: .opacity),
                    removal: .opacity
                ))
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, alignment: .center)
        .animation(.easeInOut(duration: 0.22), value: center.state)
        // Only the pills take hits; the strip stays transparent to clicks.
        .allowsHitTesting(!center.state.isEmpty)
    }
}

/// One toast: a severity rail, a glyph, the title, an optional monospace
/// body, an optional action, and the close cross. As tall as its text and no
/// taller: the rail is a shape, which would otherwise take whatever height
/// the window offers.
struct NotificationToast: View {

    let notification: DishNotification
    let onDismiss: () -> Void

    private let words = L10n.app

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Rectangle()
                .fill(severityColor(notification.severity))
                .frame(width: 4)
                .clipShape(RoundedRectangle(cornerRadius: 2))
            if let glyph = notification.glyph {
                Image(systemName: glyph)
                    .font(DishFont.toastGlyph)
                    .foregroundColor(severityColor(notification.severity))
                    .frame(width: 18)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(notification.title)
                    .font(DishFont.toastTitle)
                    .foregroundColor(DishTheme.onSurface)
                    .fixedSize(horizontal: false, vertical: true)
                if let body = notification.body, !body.isEmpty {
                    Text(body)
                        .font(DishFont.mono)
                        .foregroundColor(DishTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            if let action = notification.action {
                Button(action.label) {
                    action.handler()
                    onDismiss()
                }
                .buttonStyle(DishOutlinedButtonStyle())
            }
            if notification.dismissible {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(DishFont.closeGlyph)
                        .foregroundColor(DishTheme.muted)
                        .padding(4)
                }
                .buttonStyle(.plain)
                .help(words.dismiss)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(DishTheme.surface)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(DishTheme.outline, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .shadow(color: DishTheme.shadow, radius: 6, x: 0, y: 3)
        .frame(maxWidth: 460)
    }
}
