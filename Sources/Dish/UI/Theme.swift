// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import SwiftUI

/// The palette, shared with every Dish client (the cross-repo token schema
/// in DESIGN.md). Every colour a view draws is one of these names.
enum DishTheme {
    static let background = Color(hex: 0x060818)
    static let surface = Color(hex: 0x0C1027)
    static let surfaceDim = Color(hex: 0x131A3A)
    static let primary = Color(hex: 0x4FE3FF)
    static let primaryDark = Color(hex: 0x2C93AD)
    static let onPrimary = Color(hex: 0x060818)
    static let onSurface = Color(hex: 0xE6ECFF)
    static let muted = Color(hex: 0x93A0C8)
    static let outline = Color(hex: 0x4FE3FF, alpha: 0.18)
    static let success = Color(hex: 0x22C55E)
    static let error = Color(hex: 0xE74C3C)
    static let warning = Color(hex: 0xF59E0B)
    static let cardStroke = Color(hex: 0x4FE3FF, alpha: 0.12)

    /// A pressed outlined button.
    static let pressedFill = Color(hex: 0x4FE3FF, alpha: 0.12)
    /// A capability chip whose feature is on.
    static let chipFill = Color(hex: 0x4FE3FF, alpha: 0.14)
    /// The inline error strip.
    static let errorFill = Color(hex: 0xE74C3C, alpha: 0.12)
    /// The spinner's resting ring.
    static let spinnerTrack = Color(hex: 0x4FE3FF, alpha: 0.25)
    /// The indeterminate bar's track.
    static let barTrack = Color(hex: 0x4FE3FF, alpha: 0.22)
    /// A toast's drop shadow.
    static let shadow = Color(hex: 0x000000, alpha: 0.35)

    /// The brand glyphs' fill, from the brand book rather than the UI accent.
    static let brandGlyph = Color(hex: 0x8FCFE3)
    /// A glyph in its "off" state.
    static let brandGlyphOff = Color(hex: 0x8FCFE3, alpha: 0.4)
    /// The Bluetooth rune in its "off" state.
    static let brandRuneOff = Color(hex: 0x8FCFE3, alpha: 0.45)
    /// A glyph's white highlight.
    static let brandGlyphHighlight = Color(hex: 0xFFFFFF, alpha: 0.55)
    /// The highlight of a glyph in its "off" state.
    static let brandGlyphHighlightOff = Color(hex: 0xFFFFFF, alpha: 0.22)
    /// The dark cut under an "off" slash, for contrast on any ground.
    static let brandSlashCut = Color(hex: 0x0F1620)
}

/// The type scale. Every font a view sets is one of these names.
enum DishFont {
    /// The Connections sheet's headline.
    static let windowTitle = Font.system(size: 18, weight: .semibold)
    /// The dashboard status line and the Settings headline.
    static let title = Font.system(size: 17, weight: .semibold)
    /// The pairing sheet's headline.
    static let sheetTitle = Font.system(size: 16, weight: .semibold)
    /// A row's name or a toggle's title.
    static let body = Font.system(size: 14, weight: .medium)
    /// An icon-only button's glyph.
    static let icon = Font.system(size: 14)
    /// The PIN field.
    static let monoField = Font.system(size: 14, design: .monospaced)
    /// A toast's leading glyph.
    static let toastGlyph = Font.system(size: 14, weight: .semibold)
    /// A toast's headline.
    static let toastTitle = Font.system(size: 13, weight: .semibold)
    /// Secondary copy, hints and text fields.
    static let detail = Font.system(size: 12)
    /// Button labels and the bind picker's row names.
    static let control = Font.system(size: 12, weight: .medium)
    /// A row's second line and a toggle's explanation.
    static let caption = Font.system(size: 11)
    /// Section eyebrows and a toast's monospace body.
    static let mono = Font.system(size: 11, design: .monospaced)
    /// Chip labels and the battery percentage.
    static let micro = Font.system(size: 10, weight: .medium)
    /// The battery glyph and the bind picker's detail line.
    static let microRegular = Font.system(size: 10)
    /// A row's status chip.
    static let monoChip = Font.system(size: 10, design: .monospaced)
    /// The close cross on a banner.
    static let closeGlyph = Font.system(size: 10, weight: .bold)
}

extension Color {
    init(hex: UInt32, alpha: Double = 1.0) {
        let red = Double((hex >> 16) & 0xFF) / 255.0
        let green = Double((hex >> 8) & 0xFF) / 255.0
        let blue = Double(hex & 0xFF) / 255.0
        self.init(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }
}

/// A tracked, monospaced section eyebrow in the accent colour.
struct SectionHeader: View {
    let title: String
    var body: some View {
        Text(title)
            .font(DishFont.mono)
            .tracking(1.3)
            .foregroundColor(DishTheme.primary)
    }
}

/// The small coloured status dot.
struct StatusDot: View {
    let color: Color
    var body: some View {
        Circle().fill(color).frame(width: 8, height: 8)
    }
}

/// The outlined button. A disabled button drops to 0.4 opacity, so with the
/// in-button spinner "disabled" and "working" read as one state.
struct DishOutlinedButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        DishOutlinedButtonLabel(configuration: configuration)
    }
}

private struct DishOutlinedButtonLabel: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .font(DishFont.control)
            .foregroundColor(DishTheme.primary)
            .padding(.vertical, 6)
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(DishTheme.primary, lineWidth: 1)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(configuration.isPressed && isEnabled ? DishTheme.pressedFill : Color.clear)
                    )
            )
            .opacity(isEnabled ? 1.0 : 0.4)
            .animation(.easeInOut(duration: 0.08), value: isEnabled)
    }
}
