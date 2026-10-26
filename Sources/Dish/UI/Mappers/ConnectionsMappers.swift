// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishEngine
import Foundation

struct ConnectionsPageState: Equatable {
    let rows: [ConnectionRow]
    /// The hint in place of the rows while there are none.
    let emptyHint: String?
    let scanning: Bool
}

func connectionsPageState(
    connections: [ConnectionSummary],
    discovered: [DiscoveredServer],
    scanning: Bool,
    words: L10n = .app
) -> ConnectionsPageState {
    let rows = connectionRows(known: satelliteSummaries(connections), discovered: discovered)
    return ConnectionsPageState(rows: rows, emptyHint: rows.isEmpty ? words.pressScanHint : nil, scanning: scanning)
}
