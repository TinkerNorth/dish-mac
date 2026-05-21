// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import SwiftUI

/// Stacked toast strip rendered at the bottom-center of the window. Reads
/// `DishNotificationCenter.visible` and animates entries / exits with the
/// brand fade + slide. Drop in via `.overlay(NotificationOverlay(), alignment:
/// .bottom)` on the root scene; the host wires a single
/// `DishNotificationCenter` into the environment.
struct NotificationOverlay: View {

    @EnvironmentObject var center: DishNotificationCenter

    var body: some View {
        VStack(spacing: 8) {
            // The newest notification stacks on top so the user sees the
            // most recent surface above older ones still waiting to fade.
            // Reversing the queue keeps `visible` in insertion order (the
            // queue's natural orientation) while rendering newest-first.
            ForEach(center.visible.reversed()) { notification in
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
        .animation(.easeInOut(duration: 0.22), value: center.visible)
        // Hit-test only the toast pills themselves: the bottom strip is
        // transparent to taps so the user can still interact with content
        // underneath (Manage button, slot cards, ...) while a banner is up.
        .allowsHitTesting(!center.visible.isEmpty)
    }
}

/// One toast row. Mirrors the brand pill rendered by
/// `MaterialSnackbarRenderer` on Android: severity rail on the leading
/// edge, SF Symbol glyph, title (bold), optional monospace body, optional
/// action button, optional close button.
struct NotificationToast: View {

    let notification: DishNotification
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            // Severity rail (4 pt wide vertical accent at the leading
            // edge). Matches Android's LayerDrawable rail.
            Rectangle()
                .fill(railColor)
                .frame(width: 4)
                .clipShape(RoundedRectangle(cornerRadius: 2))
            if let glyph = notification.glyph {
                Image(systemName: glyph)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(railColor)
                    .frame(width: 18)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(notification.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DishTheme.onSurface)
                    .fixedSize(horizontal: false, vertical: true)
                if let body = notification.body, !body.isEmpty {
                    Text(body)
                        .font(.system(size: 11, design: .monospaced))
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
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(DishTheme.muted)
                        .padding(4)
                }
                .buttonStyle(.plain)
                .help(Text("Dismiss"))
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(DishTheme.surface)
        .overlay(
            RoundedRectangle(cornerRadius: 10).stroke(DishTheme.outline, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .shadow(color: Color.black.opacity(0.35), radius: 6, x: 0, y: 3)
        .frame(maxWidth: 460)
    }

    private var railColor: Color {
        switch notification.severity {
        case .info: DishTheme.primary
        case .success: DishTheme.success
        case .warn: DishTheme.warning
        case .error: DishTheme.error
        }
    }
}
