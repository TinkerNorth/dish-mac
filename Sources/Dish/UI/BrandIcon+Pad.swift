// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import SwiftUI

/// The controller glyph, the fleet's `resources/brand/pad.svg`: a body with
/// two grips, a d-pad and four face buttons. The one rail silhouette that is
/// neither a dish, a satellite nor a gear.
extension BrandIcon {

    /// The body, then the two grips, in the 64-unit canvas.
    static let padBody = CGRect(x: 6, y: 21, width: 52, height: 24)
    static let padGripCentres = [CGPoint(x: 17, y: 42), CGPoint(x: 47, y: 42)]
    static let padGripRadius: CGFloat = 11
    /// The d-pad's two bars.
    static let padCross = [CGRect(x: 11, y: 29, width: 15, height: 5), CGRect(x: 16, y: 24, width: 5, height: 15)]
    /// Top, right, bottom and left face buttons.
    static let padFaceButtons = [CGPoint(x: 43, y: 26), CGPoint(x: 50, y: 32), CGPoint(x: 43, y: 38), CGPoint(x: 36, y: 32)]
    static let padFaceButtonRadius: CGFloat = 3.5

    func drawPad(in ctx: inout GraphicsContext) {
        let s = scale
        ctx.fill(Path(roundedRect: scaled(Self.padBody, s), cornerRadius: 12 * s), with: .color(glyph))
        for centre in Self.padGripCentres {
            ctx.fill(Path(ellipseIn: circle(centre, radius: Self.padGripRadius, s)), with: .color(glyph))
        }
        for bar in Self.padCross {
            ctx.fill(Path(scaled(bar, s)), with: .color(highlight))
        }
        for centre in Self.padFaceButtons {
            ctx.fill(Path(ellipseIn: circle(centre, radius: Self.padFaceButtonRadius, s)), with: .color(highlight))
        }
    }

    private func scaled(_ rect: CGRect, _ s: CGFloat) -> CGRect {
        CGRect(x: rect.minX * s, y: rect.minY * s, width: rect.width * s, height: rect.height * s)
    }

    private func circle(_ centre: CGPoint, radius: CGFloat, _ s: CGFloat) -> CGRect {
        CGRect(x: (centre.x - radius) * s, y: (centre.y - radius) * s, width: 2 * radius * s, height: 2 * radius * s)
    }
}
