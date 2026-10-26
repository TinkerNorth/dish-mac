// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import AppKit
import SwiftUI

/// The palette, shared with every Dish client (the cross-repo token schema
/// in DESIGN.md). Every colour a view draws is one of these names, and each
/// resolves to its dark or light value with the window's appearance, which
/// the theme mode sets.
enum DishTheme {
    static let background = Color(dark: 0x060818, light: 0xF5F7FC)
    static let surface = Color(dark: 0x0C1027, light: 0xFFFFFF)
    static let surfaceDim = Color(dark: 0x131A3A, light: 0xE7ECF6)
    static let primary = Color(dark: 0x4FE3FF, light: 0x0E7C97)
    static let primaryDark = Color(dark: 0x2C93AD, light: 0x0A5E73)
    static let onPrimary = Color(dark: 0x060818, light: 0xFFFFFF)
    static let onSurface = Color(dark: 0xE6ECFF, light: 0x0C1430)
    static let muted = Color(dark: 0x93A0C8, light: 0x5A6680)
    static let outline = Color(dark: 0x4FE3FF, light: 0x0E7C97, alpha: 0.18)
    static let success = Color(dark: 0x22C55E, light: 0x1B873F)
    static let error = Color(dark: 0xE74C3C, light: 0xC0392B)
    static let warning = Color(dark: 0xF59E0B, light: 0xB7791F)
    static let cardStroke = Color(dark: 0x4FE3FF, light: 0x0E7C97, alpha: 0.12)

    /// A pressed outlined button.
    static let pressedFill = Color(dark: 0x4FE3FF, light: 0x0E7C97, alpha: 0.12)
    /// A capability chip whose feature is on.
    static let chipFill = Color(dark: 0x4FE3FF, light: 0x0E7C97, alpha: 0.14)
    /// The inline error strip.
    static let errorFill = Color(dark: 0xE74C3C, light: 0xC0392B, alpha: 0.12)
    /// The spinner's resting ring.
    static let spinnerTrack = Color(dark: 0x4FE3FF, light: 0x0E7C97, alpha: 0.25)
    /// The indeterminate bar's track.
    static let barTrack = Color(dark: 0x4FE3FF, light: 0x0E7C97, alpha: 0.22)
    /// A toast's drop shadow.
    static let shadow = Color(dark: 0x000000, light: 0x0C1430, alpha: 0.35)
    /// The rail item of the destination on screen.
    static let railActiveFill = Color(dark: 0x4FE3FF, light: 0x0E7C97, alpha: 0.14)
    /// The shell's streaming pill.
    static let pillFill = Color(dark: 0x4FE3FF, light: 0x0E7C97, alpha: 0.14)
    /// The wash under an in-page overlay.
    static let scrim = Color(dark: 0x000000, light: 0x0C1430, alpha: 0.45)
    /// The one hue beyond the accent, kept for donations: the rail's heart
    /// and the Support page's call to action.
    static let pulse = Color(dark: 0xFF6FB5, light: 0xC2417F)

    /// The brand glyphs' fill, from the brand book rather than the UI accent.
    static let brandGlyph = Color(dark: 0x8FCFE3, light: 0x2F7E96)
    /// A glyph in its "off" state.
    static let brandGlyphOff = Color(dark: 0x8FCFE3, light: 0x2F7E96, alpha: 0.4)
    /// The Bluetooth rune in its "off" state.
    static let brandRuneOff = Color(dark: 0x8FCFE3, light: 0x2F7E96, alpha: 0.45)
    /// A glyph's white highlight.
    static let brandGlyphHighlight = Color(dark: 0xFFFFFF, light: 0xFFFFFF, alpha: 0.55)
    /// The highlight of a glyph in its "off" state.
    static let brandGlyphHighlightOff = Color(dark: 0xFFFFFF, light: 0xFFFFFF, alpha: 0.22)
    /// The dark cut under an "off" slash, for contrast on any ground.
    static let brandSlashCut = Color(dark: 0x0F1620, light: 0xF5F7FC)
}

/// The shell's measures. Every size a kit component sets is one of these
/// names; the window's sizes are the desktops'.
enum DishSize {
    /// The labelled rail.
    static let railExpanded: CGFloat = 236
    /// The collapsed rail, an icon strip.
    static let railCompact: CGFloat = 52
    /// A rail glyph's cell.
    static let railGlyph: CGFloat = 18
    /// A rail item's height.
    static let railItemHeight: CGFloat = 34
    /// The rail's active-destination bar.
    static let railAccentBar: CGFloat = 3
    /// The update badge on a rail glyph.
    static let badge: CGFloat = 7
    /// The window as it first opens.
    static let windowDefaultWidth: CGFloat = 980
    static let windowDefaultHeight: CGFloat = 640
    /// The smallest the window goes.
    static let windowMinWidth: CGFloat = 900
    static let windowMinHeight: CGFloat = 620
    /// Settings lays its sections in two columns from this page width.
    static let wideBreakpoint: CGFloat = 980
    /// A hairline divider.
    static let hairline: CGFloat = 1
    /// A spinner inside a button.
    static let buttonSpinner: CGFloat = 12
    /// A chip's and a rail item's corner.
    static let chipRadius: CGFloat = 6
    /// A card's corner.
    static let cardRadius: CGFloat = 8
    /// The dash of an absent capability's outline.
    static let chipDash: CGFloat = 3
    /// The pad-to-host wire's stroke, its dash, and the dish glyph on it.
    static let wireStroke: CGFloat = 2
    static let wireDash: CGFloat = 4
    static let wireGlyph: CGFloat = 20
    /// A signal-path node's narrowest width.
    static let nodeMinWidth: CGFloat = 200
    /// The apply overlay's card.
    static let overlayWidth: CGFloat = 380
    /// A step dot on the welcome and a pip in the setup walk.
    static let stepDot: CGFloat = 8
    /// The welcome's text column.
    static let welcomeColumn: CGFloat = 460
    /// The mark on the welcome's first page.
    static let welcomeMark: CGFloat = 64
    /// Help & FAQ's reading column.
    static let helpColumn: CGFloat = 640
}

/// The spacing scale.
enum DishSpace {
    static let s1: CGFloat = 2
    static let s2: CGFloat = 4
    static let s3: CGFloat = 6
    static let s4: CGFloat = 8
    static let s5: CGFloat = 10
    static let s6: CGFloat = 12
    static let s8: CGFloat = 16
    /// A page's inset from the content column's edges.
    static let page: CGFloat = 24
}

/// The type scale. Every font a view sets is one of these names.
enum DishFont {
    /// The shell header's page title.
    static let pageTitle = Font.system(size: 20, weight: .bold)
    /// The Support page's headline.
    static let title = Font.system(size: 17, weight: .semibold)
    /// A rail item's label.
    static let railLabel = Font.system(size: 13)
    /// The rail item of the destination on screen.
    static let railLabelActive = Font.system(size: 13, weight: .semibold)
    /// A row's name or a toggle's title.
    static let body = Font.system(size: 14, weight: .medium)
    /// An icon-only button's glyph.
    static let icon = Font.system(size: 14)
    /// A PIN cell's digit on the pairing card.
    static let pinDigit = Font.system(size: 22, weight: .semibold, design: .monospaced)
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
    /// A colour that follows the window's appearance: `dark` under a dark
    /// appearance, `light` otherwise, both sRGB hex with one alpha.
    init(dark: UInt32, light: UInt32, alpha: Double = 1.0) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light, alpha: alpha)
        })
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: Double) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: CGFloat(alpha)
        )
    }
}

/// A tracked, monospaced section eyebrow in the accent colour.
struct SectionHeader: View {
    let title: String
    var body: some View {
        Text(title)
            .textCase(.uppercase)
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
