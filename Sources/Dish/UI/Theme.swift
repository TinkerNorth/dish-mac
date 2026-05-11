// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import SwiftUI

/// Color palette lifted verbatim from `dish-android/res/values/colors.xml` so
/// every Dish client renders identically. Same names as the cross-repo
/// schema (see /BRAND.md and DESIGN.md across all Dish repos).
enum DishTheme {
    static let background = Color(hex: 0x060818)  // --tn-ink
    static let surface = Color(hex: 0x0C1027)     // --tn-night
    static let surfaceDim = Color(hex: 0x131A3A)  // --tn-deep
    static let primary = Color(hex: 0x4FE3FF)     // --tn-signal (cyan)
    static let primaryDark = Color(hex: 0x2C93AD) // --tn-signal-dim
    static let onPrimary = Color(hex: 0x060818)
    static let onSurface = Color(hex: 0xE6ECFF)   // --body-color
    static let muted = Color(hex: 0x93A0C8)       // --muted
    /// Web uses rgba(79,227,255,0.18) for outline; Swift equivalent below.
    static let outline = Color(hex: 0x4FE3FF, alpha: 0.18)
    static let success = Color(hex: 0x22C55E)
    static let error = Color(hex: 0xE74C3C)
    static let warning = Color(hex: 0xF59E0B)
    /// Primary at ~12% alpha — matches colorCardStroke (#1F4FE3FF).
    static let cardStroke = Color(hex: 0x4FE3FF, alpha: 0.12)
}

extension Color {
    init(hex: UInt32, alpha: Double = 1.0) {
        let red = Double((hex >> 16) & 0xFF) / 255.0
        let green = Double((hex >> 8) & 0xFF) / 255.0
        let blue = Double(hex & 0xFF) / 255.0
        self.init(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }
}

/// Section label style (monospace, yellow, spaced) — matches the
/// `TextView` with `textColor="@color/colorPrimary"` + `fontFamily="monospace"`
/// + `letterSpacing="0.12"` used throughout `activity_main.xml`.
struct SectionHeader: View {
    let title: String
    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .regular, design: .monospaced))
            .tracking(1.3)
            .foregroundColor(DishTheme.primary)
    }
}

/// The small coloured dot used in the status row.
struct StatusDot: View {
    let color: Color
    var body: some View {
        Circle().fill(color).frame(width: 8, height: 8)
    }
}

/// Outlined button styled to match `Widget.Dish.Button.Outlined`.
struct DishOutlinedButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(DishTheme.primary)
            .padding(.vertical, 6)
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(DishTheme.primary, lineWidth: 1)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(configuration.isPressed
                                ? DishTheme.primary.opacity(0.12)
                                : Color.clear)
                    )
            )
    }
}
