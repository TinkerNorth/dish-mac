// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishEngine
import SwiftUI

/// Connection-kind selector for [BrandIcon]. Matches `ConnectionKind` in
/// dish-android and the icon families shipped in:
///   • dish-android/res/drawable/ic_{dish,satellite,bluetooth}…xml
///   • dish-website/public/img/icons/{dish,satellite,bluetooth}-*.svg
///   • satellite/web/img/icons/{dish,satellite,bluetooth}-*.svg
///
/// Pick the kind that maps to the row's transport — a Wi-Fi server row gets
/// `.dish`, a Bluetooth-HID host row gets `.bluetooth`, and the server-side
/// `.satellite` glyph is reserved for surfaces that talk about the receiver.
enum BrandIconKind {
    case dish
    case satellite
    case bluetooth
}

/// Lifecycle state for a connection row. The label vocabulary mirrors
/// `LinkState` in [ConnectionsView.statusText]; the glyph for each state is
/// chosen by [BrandIcon.body] below.
enum BrandIconState {
    case `default`
    case connected
    case searching
    case off
}

/// The brand iconography drawn with `Path` on a 64-unit canvas, crisp at
/// every size. The colours are the theme's brand tokens.
struct BrandIcon: View {
    let kind: BrandIconKind
    let state: BrandIconState
    var size: CGFloat = 28
    /// Override the canvas scale used to map the 64-unit SVG viewBox onto
    /// the rendered frame. Default is `size / 64`.
    private var scale: CGFloat {
        size / 64.0
    }

    var body: some View {
        Canvas { ctx, _ in
            switch kind {
            case .dish: drawDish(in: &ctx)
            case .satellite: drawSatellite(in: &ctx)
            case .bluetooth: drawBluetooth(in: &ctx)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    // MARK: - Palette (the brand book's glyph colours, from the theme)

    /// The glyph fill, dimmed in the "off" state.
    private var glyph: Color {
        state == .off ? DishTheme.brandGlyphOff : DishTheme.brandGlyph
    }

    /// The white highlight, dimmed in the "off" state.
    private var highlight: Color {
        state == .off ? DishTheme.brandGlyphHighlightOff : DishTheme.brandGlyphHighlight
    }

    // MARK: - Dish

    private func drawDish(in ctx: inout GraphicsContext) {
        drawDishStand(in: &ctx)
        drawDishReflector(in: &ctx)
        drawDishIndicators(in: &ctx)
    }

    /// Base plate and pole.
    private func drawDishStand(in ctx: inout GraphicsContext) {
        let p = glyph
        let s = scale
        ctx.fill(
            Path(roundedRect: CGRect(x: 14 * s, y: 56 * s, width: 36 * s, height: 4 * s), cornerRadius: 1 * s),
            with: .color(p)
        )
        ctx.fill(Path(CGRect(x: 30 * s, y: 42 * s, width: 4 * s, height: 14 * s)), with: .color(p))
    }

    /// Reflector, highlight, feed horn and mast, rotated around the pivot and
    /// rotated back so later drawing stays in canvas coordinates.
    private func drawDishReflector(in ctx: inout GraphicsContext) {
        let p = glyph
        let o = highlight
        let s = scale
        let pivot = CGPoint(x: 32 * s, y: 28 * s)
        ctx.translateBy(x: pivot.x, y: pivot.y)
        ctx.rotate(by: .degrees(Self.reflectorTiltDegrees))
        ctx.translateBy(x: -pivot.x, y: -pivot.y)
        ctx.fill(Path(ellipseIn: CGRect(x: 8 * s, y: 20 * s, width: 48 * s, height: 16 * s)), with: .color(p))
        ctx.fill(Path(ellipseIn: CGRect(x: 14 * s, y: 24 * s, width: 36 * s, height: 8 * s)), with: .color(o))
        ctx.fill(Path(ellipseIn: CGRect(x: 29 * s, y: 25 * s, width: 6 * s, height: 6 * s)), with: .color(p))
        ctx.fill(Path(CGRect(x: 30 * s, y: 14 * s, width: 4 * s, height: 14 * s)), with: .color(p))
        ctx.translateBy(x: pivot.x, y: pivot.y)
        ctx.rotate(by: .degrees(-Self.reflectorTiltDegrees))
        ctx.translateBy(x: -pivot.x, y: -pivot.y)
    }

    /// The reflector's tilt in the 64-unit glyph.
    private static let reflectorTiltDegrees: Double = -28

    private func drawDishIndicators(in ctx: inout GraphicsContext) {
        let s = scale
        if state == .connected {
            ctx.fill(Path(ellipseIn: CGRect(x: 45 * s, y: 11 * s, width: 6 * s, height: 6 * s)), with: .color(DishTheme.brandGlyph))
            ctx.fill(
                Path(ellipseIn: CGRect(x: 46.5 * s, y: 12.5 * s, width: 3 * s, height: 3 * s)),
                with: .color(DishTheme.brandGlyphHighlight)
            )
        }
        if state == .off {
            strokeSlash(in: &ctx)
        }
    }

    // MARK: - Satellite

    private func drawSatellite(in ctx: inout GraphicsContext) {
        drawSolarPanels(in: &ctx)
        drawSatelliteBody(in: &ctx)
        drawAntenna(in: &ctx)
        drawSatelliteIndicators(in: &ctx)
    }

    /// Two panels with their slats and the connectors to the body.
    private func drawSolarPanels(in ctx: inout GraphicsContext) {
        let p = glyph
        let o = highlight
        let s = scale
        for x in [2, 42] {
            ctx.fill(
                Path(roundedRect: CGRect(x: CGFloat(x) * s, y: 28 * s, width: 20 * s, height: 10 * s), cornerRadius: 1 * s),
                with: .color(p)
            )
        }
        for x in [6, 10, 14, 18, 46, 50, 54, 58] {
            ctx.fill(Path(CGRect(x: CGFloat(x) * s, y: 29 * s, width: 1 * s, height: 8 * s)), with: .color(o))
        }
        for x in [22, 38] {
            ctx.fill(Path(CGRect(x: CGFloat(x) * s, y: 31 * s, width: 4 * s, height: 4 * s)), with: .color(p))
        }
    }

    private func drawSatelliteBody(in ctx: inout GraphicsContext) {
        let p = glyph
        let o = highlight
        let s = scale
        ctx.fill(
            Path(roundedRect: CGRect(x: 26 * s, y: 22 * s, width: 12 * s, height: 20 * s), cornerRadius: 2 * s),
            with: .color(p)
        )
        ctx.fill(
            Path(roundedRect: CGRect(x: 28 * s, y: 25 * s, width: 8 * s, height: 4 * s), cornerRadius: 1 * s),
            with: .color(o)
        )
    }

    /// Mast plus the antenna's chevron.
    private func drawAntenna(in ctx: inout GraphicsContext) {
        let p = glyph
        let s = scale
        ctx.fill(Path(CGRect(x: 31 * s, y: 10 * s, width: 2 * s, height: 12 * s)), with: .color(p))
        var chevron = Path()
        chevron.move(to: CGPoint(x: 27 * s, y: 8 * s))
        chevron.addQuadCurve(to: CGPoint(x: 37 * s, y: 8 * s), control: CGPoint(x: 32 * s, y: 2 * s))
        chevron.addLine(to: CGPoint(x: 34 * s, y: 10 * s))
        chevron.addQuadCurve(to: CGPoint(x: 30 * s, y: 10 * s), control: CGPoint(x: 32 * s, y: 5 * s))
        chevron.closeSubpath()
        ctx.fill(chevron, with: .color(p))
    }

    private func drawSatelliteIndicators(in ctx: inout GraphicsContext) {
        let s = scale
        if state == .connected {
            ctx.fill(
                Path(ellipseIn: CGRect(x: 29.5 * s, y: -0.5 * s, width: 5 * s, height: 5 * s)),
                with: .color(DishTheme.brandGlyph)
            )
        }
        if state == .off {
            strokeSlash(in: &ctx)
        }
    }

    // MARK: - Bluetooth

    private func drawBluetooth(in ctx: inout GraphicsContext) {
        drawBluetoothRune(in: &ctx)
        drawBluetoothIndicators(in: &ctx)
    }

    private func drawBluetoothRune(in ctx: inout GraphicsContext) {
        let s = scale
        let stroke = state == .off ? DishTheme.brandRuneOff : DishTheme.brandGlyph
        var rune = Path()
        let points: [(CGFloat, CGFloat)] = [(18, 18), (46, 46), (32, 58), (32, 6), (46, 18), (18, 46)]
        rune.move(to: CGPoint(x: points[0].0 * s, y: points[0].1 * s))
        for point in points.dropFirst() {
            rune.addLine(to: CGPoint(x: point.0 * s, y: point.1 * s))
        }
        ctx.stroke(rune, with: .color(stroke), style: StrokeStyle(lineWidth: 6 * s, lineCap: .round, lineJoin: .round))
    }

    private func drawBluetoothIndicators(in ctx: inout GraphicsContext) {
        let s = scale
        switch state {
        case .connected:
            ctx.fill(
                Path(ellipseIn:
                    CGRect(x: 3 * s, y: 29 * s, width: 6 * s, height: 6 * s)),
                with: .color(DishTheme.brandGlyph)
            )
            ctx.fill(
                Path(ellipseIn:
                    CGRect(x: 55 * s, y: 29 * s, width: 6 * s, height: 6 * s)),
                with: .color(DishTheme.brandGlyph)
            )
        case .searching:
            var arc = Path()
            arc.move(to: CGPoint(x: 56 * s, y: 24 * s))
            arc.addRelativeArc(
                center: CGPoint(x: 56 * s, y: 32 * s),
                radius: 9 * s,
                startAngle: .degrees(-90),
                delta: .degrees(180)
            )
            ctx.stroke(
                arc,
                with: .color(DishTheme.brandGlyph),
                style: StrokeStyle(lineWidth: 4 * s, lineCap: .round)
            )
        case .off:
            strokeSlash(in: &ctx)
        case .default:
            break
        }
    }

    /// Shared slash overlay for the .off states. Dark cutout under teal stroke
    /// for contrast on either background, matching the SVG masters.
    private func strokeSlash(in ctx: inout GraphicsContext) {
        let s = scale
        var line = Path()
        line.move(to: CGPoint(x: 10 * s, y: 54 * s))
        line.addLine(to: CGPoint(x: 54 * s, y: 10 * s))
        ctx.stroke(
            line,
            with: .color(DishTheme.brandSlashCut),
            style: StrokeStyle(lineWidth: 8 * s, lineCap: .round)
        )
        ctx.stroke(
            line,
            with: .color(DishTheme.brandGlyph),
            style: StrokeStyle(lineWidth: 4 * s, lineCap: .round)
        )
    }
}

extension BrandIcon {
    /// The glyph for a Wi-Fi-server row. Each row is a satellite the Mac is
    /// reaching out to, so the satellite silhouette is the right one; the
    /// dish glyph would read as the sender.
    static func satellite(for state: LinkState, size: CGFloat = 28) -> BrandIcon {
        BrandIcon(kind: .satellite, state: brandIconState(for: state), size: size)
    }
}
