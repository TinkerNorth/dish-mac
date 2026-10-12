// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishEngine
import SwiftUI

// Three indeterminate progress indicators from the brand's loader spec
// (`LoaderSpinner`, `LoaderDots`, `LoaderBar`). The proportions and timings
// follow the spec; the colour is the UI accent.
//
//   · `DishSpinner` for short, bounded waits (network calls, scans).
//   · `DishDots` for "thinking" states.
//   · `DishBar` for whole-area loading.

/// A rotating arc on a 64-unit canvas: the stroke is 6/64 of the size, the
/// arc covers 50/138 of the ring, and one turn takes 1.2 s.
struct DishSpinner: View {

    var size: CGFloat = 16
    @State private var rotate = false

    var body: some View {
        let stroke = size * (6.0 / 64.0)
        let arcFraction: CGFloat = 50.0 / 138.0
        return ZStack {
            Circle()
                .stroke(DishTheme.spinnerTrack, lineWidth: stroke)
            Circle()
                .trim(from: 0, to: arcFraction)
                .stroke(DishTheme.primary, style: StrokeStyle(lineWidth: stroke, lineCap: .round))
                .rotationEffect(.degrees(rotate ? 360 : 0))
                .animation(.linear(duration: 1.2).repeatForever(autoreverses: false), value: rotate)
        }
        .frame(width: size, height: size)
        .onAppear { rotate = true }
        .accessibilityLabel(L10n.app.loading)
    }
}

/// Three dots pulsing in opacity (0.25 to 1) and radius (4 to 6 units) on a
/// 1.2 s triangle wave, staggered 0.18 s apart.
struct DishDots: View {

    var size: CGFloat = 16

    var body: some View {
        TimelineView(.animation) { timeline in
            let now = timeline.date.timeIntervalSinceReferenceDate
            let scale = size / 64.0
            HStack(spacing: scale * 6.0) {
                ForEach(0 ..< 3, id: \.self) { index in
                    let phase = ((now + Double(index) * 0.18).truncatingRemainder(dividingBy: 1.2)) / 1.2
                    let tri = CGFloat(1.0 - abs(phase - 0.5) * 2.0)
                    let opacity = 0.25 + 0.75 * Double(tri)
                    let radius = scale * (4.0 + 2.0 * tri)
                    Circle()
                        .fill(DishTheme.primary)
                        .frame(width: radius * 2, height: radius * 2)
                        .opacity(opacity)
                }
            }
            .frame(width: size, height: size)
        }
        .accessibilityLabel(L10n.app.working)
    }
}

/// An 80-unit highlight sliding across a 240-unit track every 1.4 s,
/// entering and leaving through the edges.
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
            let offset = -sliderWidth + (width + sliderWidth) * phase
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: trackHeight / 2)
                    .fill(DishTheme.barTrack)
                    .frame(width: width, height: trackHeight)
                RoundedRectangle(cornerRadius: trackHeight / 2)
                    .fill(DishTheme.primary)
                    .frame(width: sliderWidth, height: trackHeight)
                    .offset(x: offset)
            }
            .frame(width: width, height: height, alignment: .leading)
            .clipped()
        }
        .accessibilityLabel(L10n.app.loading)
    }
}
