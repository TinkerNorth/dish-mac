// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishEngine
import Foundation
import SwiftUI

/// The chip word for a link state: a noun at rest, a verb with an ellipsis
/// while something is in flight.
func linkStateText(_ state: LinkState, words: L10n = .app) -> String {
    switch state {
    case .found: words.found
    case .stale: words.needsPairing
    case .saved: words.offline
    case .ready: words.ready
    case .connecting: words.connecting
    case .connected: words.online
    case .unstable: words.unsteady
    }
}

/// Only a session that is up has a latency worth showing.
func showsLatency(_ state: LinkState) -> Bool {
    switch state {
    case .connected, .unstable: true
    case .found, .stale, .saved, .ready, .connecting: false
    }
}

/// The one-way latency readout beside a live chip: a number and the SI
/// unit, with the decimal mark of `locale`.
func latencySuffix(_ latencyMs: Double, locale: Locale) -> String {
    String(format: " · %.1f ms", locale: locale, latencyMs)
}

/// The status line under a known row: the chip word, plus the latency while
/// the session is up and has paired an ack.
func statusLine(for summary: ConnectionSummary, words: L10n = .app) -> String {
    let base = linkStateText(summary.live, words: words)
    guard showsLatency(summary.live), let latencyMs = summary.latencyMs else { return base }
    return base + latencySuffix(latencyMs, locale: words.catalog.locale)
}

/// The dot beside a row: green when live, the accent while transient,
/// muted at rest.
func linkDotColor(_ state: LinkState) -> Color {
    switch state {
    case .connected: DishTheme.success
    case .connecting, .unstable: DishTheme.primary
    case .found, .stale, .saved, .ready: DishTheme.muted
    }
}

/// The satellite glyph's variant for a row: the uplink dot when live, the
/// slash when paired but out of reach, plain otherwise.
func brandIconState(for state: LinkState) -> BrandIconState {
    switch state {
    case .connected: .connected
    case .saved, .stale: .off
    case .found, .ready, .connecting, .unstable: .default
    }
}
