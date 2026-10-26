// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import SwiftUI

/// Sections in one column, or in two once the page is wide enough: the
/// first `leading` sections stack on the left, the rest on the right, each
/// column as tall as its own content.
struct TwoColumnLayout: Layout {

    let breakpoint: CGFloat
    let leading: Int
    let spacing: CGFloat

    /// Two columns from the breakpoint up, one below it.
    static func columnCount(width: CGFloat, breakpoint: CGFloat) -> Int {
        width >= breakpoint ? 2 : 1
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout Void) -> CGSize {
        let width = proposal.width ?? breakpoint
        let columns = self.columns(subviews, width: width)
        let heights = columns.map { stackHeight($0, width: columnWidth(width, count: columns.count)) }
        return CGSize(width: width, height: heights.max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout Void) {
        let columns = self.columns(subviews, width: bounds.width)
        let width = columnWidth(bounds.width, count: columns.count)
        for (index, column) in columns.enumerated() {
            let x = bounds.minX + CGFloat(index) * (width + spacing)
            place(column, x: x, top: bounds.minY, width: width)
        }
    }

    private func columns(_ subviews: Subviews, width: CGFloat) -> [[LayoutSubview]] {
        let all = Array(subviews)
        guard Self.columnCount(width: width, breakpoint: breakpoint) == 2 else { return [all] }
        let split = min(leading, all.count)
        return [Array(all[..<split]), Array(all[split...])]
    }

    private func columnWidth(_ width: CGFloat, count: Int) -> CGFloat {
        let gaps = CGFloat(count - 1) * spacing
        return (width - gaps) / CGFloat(count)
    }

    private func stackHeight(_ column: [LayoutSubview], width: CGFloat) -> CGFloat {
        let heights = column.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)).height }
        let gaps = CGFloat(max(column.count - 1, 0)) * spacing
        return heights.reduce(0, +) + gaps
    }

    private func place(_ column: [LayoutSubview], x: CGFloat, top: CGFloat, width: CGFloat) {
        var y = top
        for subview in column {
            let proposal = ProposedViewSize(width: width, height: nil)
            let height = subview.sizeThatFits(proposal).height
            subview.place(at: CGPoint(x: x, y: y), proposal: proposal)
            y += height + spacing
        }
    }
}
