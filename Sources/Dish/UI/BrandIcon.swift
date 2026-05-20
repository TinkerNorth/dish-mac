// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

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

/// Native SwiftUI rendering of the v6 brand iconography from
/// `dish-mac/../bluetooth-assets`, `dish-assets`, `satellite-assets`.
///
/// Implemented with `Path` rather than bundled SVG because dish-mac targets
/// macOS 13 (Asset Catalog SVG rendering only landed in macOS 14) and
/// adding a resource pipeline would mean rewriting Package.swift. Path-
/// drawing keeps the glyphs crisp at every size for free.
struct BrandIcon: View {
    let kind: BrandIconKind
    let state: BrandIconState
    var size: CGFloat = 28
    /// Override the canvas scale used to map the 64-unit SVG viewBox onto
    /// the rendered frame. Default is `size / 64`.
    private var scale: CGFloat { size / 64.0 }

    var body: some View {
        Canvas { ctx, _ in
            switch kind {
            case .dish:      drawDish(in: &ctx)
            case .satellite: drawSatellite(in: &ctx)
            case .bluetooth: drawBluetooth(in: &ctx)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    // MARK: - Palette (mirrors the v6 brand book)
    private var primary: Color { Color(red: 143/255, green: 207/255, blue: 227/255) }   // #8FCFE3
    private var overlay: Color { Color.white.opacity(0.55) }
    private var slashCut: Color { Color(red: 15/255, green: 22/255, blue: 32/255) }      // #0F1620

    private var primaryAlpha: Double { state == .off ? 0.4 : 1.0 }
    private var overlayAlpha: Double { state == .off ? 0.22 : 0.55 }

    // MARK: - Dish

    private func drawDish(in ctx: inout GraphicsContext) {
        let p = primary.opacity(primaryAlpha)
        let o = Color.white.opacity(overlayAlpha)
        let s = scale

        // base plate (rect 14,56 36x4 rx 1)
        ctx.fill(Path(roundedRect:
            CGRect(x: 14*s, y: 56*s, width: 36*s, height: 4*s),
            cornerRadius: 1*s), with: .color(p))
        // pole (rect 30,42 4x14)
        ctx.fill(Path(CGRect(x: 30*s, y: 42*s, width: 4*s, height: 14*s)),
                 with: .color(p))

        // reflector — rotate -28° around (32,28)
        let pivot = CGPoint(x: 32*s, y: 28*s)
        ctx.translateBy(x: pivot.x, y: pivot.y)
        ctx.rotate(by: .degrees(-28))
        ctx.translateBy(x: -pivot.x, y: -pivot.y)

        // outer dish (ellipse cx=32 cy=28 rx=24 ry=8)
        ctx.fill(Path(ellipseIn:
            CGRect(x: 8*s, y: 20*s, width: 48*s, height: 16*s)),
            with: .color(p))
        // overlay (rx=18 ry=4)
        ctx.fill(Path(ellipseIn:
            CGRect(x: 14*s, y: 24*s, width: 36*s, height: 8*s)),
            with: .color(o))
        // feed horn (circle r=3)
        ctx.fill(Path(ellipseIn:
            CGRect(x: 29*s, y: 25*s, width: 6*s, height: 6*s)),
            with: .color(p))
        // mast (rect 30,14 4x14)
        ctx.fill(Path(CGRect(x: 30*s, y: 14*s, width: 4*s, height: 14*s)),
                 with: .color(p))

        // Reset rotation before adding overlays in canvas coords.
        ctx.translateBy(x: pivot.x, y: pivot.y)
        ctx.rotate(by: .degrees(28))
        ctx.translateBy(x: -pivot.x, y: -pivot.y)

        if state == .connected {
            // lock-on indicator at (48,14)
            ctx.fill(Path(ellipseIn:
                CGRect(x: 45*s, y: 11*s, width: 6*s, height: 6*s)),
                with: .color(primary))
            ctx.fill(Path(ellipseIn:
                CGRect(x: 46.5*s, y: 12.5*s, width: 3*s, height: 3*s)),
                with: .color(.white.opacity(0.55)))
        }
        if state == .off {
            strokeSlash(in: &ctx)
        }
    }

    // MARK: - Satellite

    private func drawSatellite(in ctx: inout GraphicsContext) {
        let p = primary.opacity(primaryAlpha)
        let o = Color.white.opacity(overlayAlpha)
        let s = scale

        // Left + right solar panels
        ctx.fill(Path(roundedRect:
            CGRect(x: 2*s, y: 28*s, width: 20*s, height: 10*s), cornerRadius: 1*s),
            with: .color(p))
        ctx.fill(Path(roundedRect:
            CGRect(x: 42*s, y: 28*s, width: 20*s, height: 10*s), cornerRadius: 1*s),
            with: .color(p))
        // Slats
        for x in [6, 10, 14, 18, 46, 50, 54, 58] {
            ctx.fill(Path(CGRect(x: CGFloat(x)*s, y: 29*s,
                                 width: 1*s, height: 8*s)),
                     with: .color(o))
        }
        // Connectors
        ctx.fill(Path(CGRect(x: 22*s, y: 31*s, width: 4*s, height: 4*s)),
                 with: .color(p))
        ctx.fill(Path(CGRect(x: 38*s, y: 31*s, width: 4*s, height: 4*s)),
                 with: .color(p))
        // Body
        ctx.fill(Path(roundedRect:
            CGRect(x: 26*s, y: 22*s, width: 12*s, height: 20*s), cornerRadius: 2*s),
            with: .color(p))
        // Window
        ctx.fill(Path(roundedRect:
            CGRect(x: 28*s, y: 25*s, width: 8*s, height: 4*s), cornerRadius: 1*s),
            with: .color(o))
        // Antenna mast
        ctx.fill(Path(CGRect(x: 31*s, y: 10*s, width: 2*s, height: 12*s)),
                 with: .color(p))
        // Antenna dish (approximate chevron)
        var chev = Path()
        chev.move(to: CGPoint(x: 27*s, y: 8*s))
        chev.addQuadCurve(to: CGPoint(x: 37*s, y: 8*s),
                          control: CGPoint(x: 32*s, y: 2*s))
        chev.addLine(to: CGPoint(x: 34*s, y: 10*s))
        chev.addQuadCurve(to: CGPoint(x: 30*s, y: 10*s),
                          control: CGPoint(x: 32*s, y: 5*s))
        chev.closeSubpath()
        ctx.fill(chev, with: .color(p))

        if state == .connected {
            // uplink dot
            ctx.fill(Path(ellipseIn:
                CGRect(x: 29.5*s, y: -0.5*s, width: 5*s, height: 5*s)),
                with: .color(primary))
        }
        if state == .off {
            strokeSlash(in: &ctx)
        }
    }

    // MARK: - Bluetooth

    private func drawBluetooth(in ctx: inout GraphicsContext) {
        let s = scale
        let runeAlpha: Double = state == .off ? 0.45 : 1.0
        let stroke = primary.opacity(runeAlpha)

        var rune = Path()
        let pts: [(CGFloat, CGFloat)] = [
            (18, 18), (46, 46), (32, 58), (32, 6), (46, 18), (18, 46),
        ]
        rune.move(to: CGPoint(x: pts[0].0 * s, y: pts[0].1 * s))
        for p in pts.dropFirst() {
            rune.addLine(to: CGPoint(x: p.0 * s, y: p.1 * s))
        }
        ctx.stroke(rune, with: .color(stroke),
                   style: StrokeStyle(lineWidth: 6*s, lineCap: .round, lineJoin: .round))

        switch state {
        case .connected:
            ctx.fill(Path(ellipseIn:
                CGRect(x: 3*s, y: 29*s, width: 6*s, height: 6*s)),
                with: .color(primary))
            ctx.fill(Path(ellipseIn:
                CGRect(x: 55*s, y: 29*s, width: 6*s, height: 6*s)),
                with: .color(primary))
        case .searching:
            var arc = Path()
            arc.move(to: CGPoint(x: 56*s, y: 24*s))
            arc.addRelativeArc(center: CGPoint(x: 56*s, y: 32*s),
                               radius: 9*s,
                               startAngle: .degrees(-90),
                               delta: .degrees(180))
            ctx.stroke(arc, with: .color(primary),
                       style: StrokeStyle(lineWidth: 4*s, lineCap: .round))
        case .off:
            strokeSlash(in: &ctx)
        case .default:
            break
        }
    }

    // Shared slash overlay for the .off states. Dark cutout under teal stroke
    // for contrast on either background, matching the SVG masters.
    private func strokeSlash(in ctx: inout GraphicsContext) {
        let s = scale
        var line = Path()
        line.move(to: CGPoint(x: 10*s, y: 54*s))
        line.addLine(to: CGPoint(x: 54*s, y: 10*s))
        ctx.stroke(line, with: .color(slashCut),
                   style: StrokeStyle(lineWidth: 8*s, lineCap: .round))
        ctx.stroke(line, with: .color(primary),
                   style: StrokeStyle(lineWidth: 4*s, lineCap: .round))
    }
}

extension BrandIcon {
    /// Convenience builder that maps a Wi-Fi-server row's `LinkState` onto
    /// the right glyph state. Each row IS a satellite server the phone /
    /// laptop is reaching out to, so the satellite glyph is the correct
    /// silhouette — using the dish glyph here would read as the *sender*
    /// rather than the *target*. Mirrors the Android
    /// `rowGlyphRes(SATELLITE, …)` mapping and the Qt
    /// `brandIconResource(Satellite, …)` mapping.
    static func satellite(for state: LinkState, size: CGFloat = 28) -> BrandIcon {
        let bs: BrandIconState =
            switch state {
            case .connected: .connected
            case .saved, .stale: .off
            default: .default
            }
        return BrandIcon(kind: .satellite, state: bs, size: size)
    }
}
