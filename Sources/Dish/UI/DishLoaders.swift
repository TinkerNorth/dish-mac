// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import SwiftUI

// Three indeterminate progress indicators ported from the design spec in
// `app-icon/project/app-essentials.jsx` (sections `LoaderSpinner`,
// `LoaderDots`, `LoaderBar`). Proportions (stroke width, dasharray ratio,
// timings) are pixel-faithful to the spec; the color is `DishTheme.primary`
// rather than the spec's hard-coded `#8FCFE3` — this app's brand intentionally
// runs on a different blue (see `Theme.swift`), but every other geometric
// rule of the spec is preserved.
//
// Use:
//   · `DishSpinner` — default for short, bounded waits (network calls, scans).
//   · `DishDots`    — "thinking" states (AI generation, search suggestions).
//   · `DishBar`     — whole-area / pane-level loading.

// MARK: - Spinner ────────────────────────────────────────────────────────

/// Indeterminate rotating arc. Spec reference: `LoaderSpinner`.
///
/// - 64×64 design canvas → stroke width is `size × 6/64`.
/// - Background ring sits at 25 % alpha, full arc on top.
/// - Visible arc is `strokeDasharray="50 88"` of the circumference,
///   i.e. 50 / 138 ≈ 36.2 % of the ring (the rest is gap).
/// - 1.2 s linear rotation, indefinite.
struct DishSpinner: View {

    var size: CGFloat = 16
    @State private var rotate = false

    var body: some View {
        let stroke = size * (6.0 / 64.0)
        // dasharray "50 88" → 50 / (50 + 88) of the full circumference is the arc.
        let arcFraction: CGFloat = 50.0 / 138.0
        return ZStack {
            Circle()
                .stroke(DishTheme.primary.opacity(0.25), lineWidth: stroke)
            Circle()
                .trim(from: 0, to: arcFraction)
                .stroke(
                    DishTheme.primary,
                    style: StrokeStyle(lineWidth: stroke, lineCap: .round)
                )
                .rotationEffect(.degrees(rotate ? 360 : 0))
                .animation(
                    .linear(duration: 1.2).repeatForever(autoreverses: false),
                    value: rotate
                )
        }
        .frame(width: size, height: size)
        .onAppear { rotate = true }
        .accessibilityLabel("Loading")
    }
}

// MARK: - Dots ───────────────────────────────────────────────────────────

/// Three pulsing circles. Spec reference: `LoaderDots`.
///
/// Each dot oscillates in opacity (0.25 ↔ 1) and radius (4 ↔ 6 design units)
/// on a 1.2 s cycle, staggered 0.18 s between dots. The original SMIL
/// `<animate values="A;B;A" dur="1.2s">` is a linear interpolation that
/// produces a triangle wave — mirrored here directly so the visual matches.
struct DishDots: View {

    var size: CGFloat = 16

    var body: some View {
        // TimelineView gives us a clock-driven update without owning a
        // per-instance Timer/CADisplayLink. The body re-renders every frame
        // SwiftUI ticks the animation schedule.
        TimelineView(.animation) { timeline in
            let now = timeline.date.timeIntervalSinceReferenceDate
            let scale = size / 64.0 // design-units → points
            // Three dots at design-x 16/32/48 → spacing of 16u between centers.
            HStack(spacing: scale * 6.0) {
                ForEach(0 ..< 3, id: \.self) { i in
                    let phase = ((now + Double(i) * 0.18)
                        .truncatingRemainder(dividingBy: 1.2)) / 1.2
                    // Triangle: 0 at the edges of the cycle, 1 at the midpoint.
                    let tri = CGFloat(1.0 - abs(phase - 0.5) * 2.0)
                    let opacity = 0.25 + 0.75 * Double(tri) // 0.25 → 1
                    let r = scale * (4.0 + 2.0 * tri) // 4 → 6 (design units)
                    Circle()
                        .fill(DishTheme.primary)
                        .frame(width: r * 2, height: r * 2)
                        .opacity(opacity)
                }
            }
            .frame(width: size, height: size)
        }
        .accessibilityLabel("Working")
    }
}

// MARK: - Bar ────────────────────────────────────────────────────────────

/// Indeterminate horizontal bar — a 80-unit-wide highlight slides across a
/// 240-unit track on a 1.4 s linear cycle. Spec reference: `LoaderBar`.
///
/// The slider starts off-screen at `x = -80` and ends off-screen at
/// `x = 240`, so the bright pip animates fully through the visible area.
struct DishBar: View {

    var width: CGFloat = 240

    private var height: CGFloat {
        width * (16.0 / 240.0)
    }

    private var trackHeight: CGFloat {
        width * (8.0 / 240.0)
    }

    private var sliderWidth: CGFloat {
        width * (80.0 / 240.0)
    }

    var body: some View {
        TimelineView(.animation) { timeline in
            let now = timeline.date.timeIntervalSinceReferenceDate
            let phase = CGFloat(now.truncatingRemainder(dividingBy: 1.4) / 1.4)
            // x ∈ [-sliderWidth, width] over the cycle so the highlight
            // enters and exits cleanly through both edges.
            let x = -sliderWidth + (width + sliderWidth) * phase
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: trackHeight / 2)
                    .fill(DishTheme.primary.opacity(0.22))
                    .frame(width: width, height: trackHeight)
                RoundedRectangle(cornerRadius: trackHeight / 2)
                    .fill(DishTheme.primary)
                    .frame(width: sliderWidth, height: trackHeight)
                    .offset(x: x)
            }
            .frame(width: width, height: height, alignment: .leading)
            .clipped() // prevent the slider from spilling past the bar bounds
        }
        .accessibilityLabel("Loading")
    }
}
