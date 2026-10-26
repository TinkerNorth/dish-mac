// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishEngine
import Foundation

/// The path a server was heard on, as the found row says it.
func discoverySourceText(_ source: DiscoverySource, words: L10n = .app) -> String {
    switch source {
    case .broadcast: words.udpBroadcast
    case .mdns: words.mdns
    case .both: words.mdnsAndBroadcast
    case .manual: words.addedByAddress
    }
}

/// A server's display name: its advertised name, or its address when the
/// beacon carried none.
func serverTitle(_ server: DiscoveredServer) -> String {
    server.name.isEmpty ? server.ip : server.name
}

/// The found row's line: where the server answered, and how it was heard.
func foundServerDetail(_ server: DiscoveredServer, words: L10n = .app) -> String {
    "\(server.ip) · \(discoverySourceText(server.source, words: words))"
}

/// The servers a scan heard that no paired card already shows: a satellite
/// has one place on the page.
func foundServers(_ discovered: [DiscoveredServer], known: [ConnectionSummary]) -> [DiscoveredServer] {
    let knownIds = Set(known.map(\.id))
    return discovered.filter { !knownIds.contains($0.id) }
}
