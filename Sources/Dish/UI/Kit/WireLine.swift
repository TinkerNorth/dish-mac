// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import SwiftUI

/// The pad-to-host wire on Home: solid in the accent while the link is
/// live, dashed and muted otherwise; while a link comes up the dashes crawl
/// toward the host, because the wire must not read live before it is. The
/// caption above it is the measured rate and latency, or the link's word.
struct WireLine: View {
    let label: String
    let live: Bool
    var transmitting = false
    var showsGlyph = true
    var help = ""

    /// One crawl of the dash pattern, the loaders' pace.
    private static let crawlSeconds = 1.2

    var body: some View {
        VStack(spacing: DishSpace.s2) {
            if !label.isEmpty {
                Text(label)
                    .font(DishFont.monoChip)
                    .foregroundColor(ink)
                    .lineLimit(1)
            }
            ZStack {
                TimelineView(.animation(minimumInterval: nil, paused: !transmitting)) { timeline in
                    WireShape()
                        .stroke(ink, style: stroke(phase: phase(at: timeline.date)))
                }
                .frame(height: DishSize.wireGlyph)
                if showsGlyph {
                    BrandIcon(kind: .dish, state: live ? .connected : .off, size: DishSize.wireGlyph)
                        .background(DishTheme.surface)
                }
            }
        }
        .help(help)
    }

    private var ink: Color {
        live || transmitting ? DishTheme.primary : DishTheme.muted
    }

    private func stroke(phase: CGFloat) -> StrokeStyle {
        let dash = live ? [] : [DishSize.wireDash, DishSize.wireDash]
        return StrokeStyle(lineWidth: DishSize.wireStroke, dash: dash, dashPhase: phase)
    }

    /// Walks the pattern toward the host while transmitting; parked otherwise.
    private func phase(at date: Date) -> CGFloat {
        guard transmitting else { return 0 }
        let elapsed = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: Self.crawlSeconds)
        let share = CGFloat(elapsed / Self.crawlSeconds)
        return -share * DishSize.wireDash * 2
    }
}

private struct WireShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return path
    }
}
