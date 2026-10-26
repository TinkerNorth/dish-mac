// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import SwiftUI

/// Chips in reading order, wrapping onto the next line rather than losing
/// one labelled fact off the edge.
struct FlowLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout Void) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = rows(subviews, width: width)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        let widest = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? widest, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout Void) {
        var y = bounds.minY
        for row in rows(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.members {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var members: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func rows(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let step = current.members.isEmpty ? size.width : current.width + spacing + size.width
            let overflows = step > width && !current.members.isEmpty
            if overflows {
                rows.append(current)
                current = Row()
            }
            current.width = current.members.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.members.append(index)
        }
        if !current.members.isEmpty { rows.append(current) }
        return rows
    }
}
