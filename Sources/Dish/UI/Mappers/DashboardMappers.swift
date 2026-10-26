// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishEngine
import Foundation
import SwiftUI

func liveConnections(_ connections: [ConnectionSummary]) -> [ConnectionSummary] {
    connections.filter { $0.live == .connected }
}

/// The dashboard headline: nothing yet, how many are paired, the one live
/// server's name, or how many are live.
func dashboardStatusText(_ connections: [ConnectionSummary], words: L10n = .app) -> String {
    let live = liveConnections(connections)
    switch (live.count, connections.count) {
    case (0, 0): return words.noConnectionsYet
    case let (0, total): return words.paired(total)
    case (1, _): return live[0].label
    case let (count, _): return words.activeConnections(count)
    }
}

/// The line under the headline: the hint, the paired count, or live of total.
func dashboardSummaryText(_ connections: [ConnectionSummary], words: L10n = .app) -> String {
    let live = liveConnections(connections).count
    let total = connections.count
    switch (live, total) {
    case (0, 0): return words.plugInAndPairToGetStarted
    case (0, _): return words.paired(total)
    case (_, _): return words.onlineOfTotal(live, total)
    }
}

/// The headline, its dot and its glyph all turn green together.
func dashboardAccent(liveCount: Int) -> Color {
    liveCount > 0 ? DishTheme.success : DishTheme.muted
}

func dashboardIconState(liveCount: Int) -> BrandIconState {
    liveCount > 0 ? .connected : .default
}
