// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishEngine
import Foundation

/// The path a server was heard on, as the chip says it.
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

/// The address line: IP and UDP port, numeric and untranslated.
func serverDetail(_ server: DiscoveredServer) -> String {
    "\(server.ip) • UDP \(server.udpPort)"
}

/// The status chip of a freshly discovered, unpaired server.
func discoveredStatusText(_ server: DiscoveredServer, words: L10n = .app) -> String {
    words.foundVia(discoverySourceText(server.source, words: words))
}

/// A row on the Connections page: a known server (remembered or live), or
/// one just discovered that the summaries do not list yet.
enum ConnectionRow: Equatable {
    case known(ConnectionSummary)
    case discovered(DiscoveredServer)

    var key: String {
        switch self {
        case let .known(summary): summary.id
        case let .discovered(server): server.id
        }
    }
}

/// Known rows first, then the discovered servers not already among them.
func connectionRows(known: [ConnectionSummary], discovered: [DiscoveredServer]) -> [ConnectionRow] {
    let knownIds = Set(known.map(\.id))
    return known.map(ConnectionRow.known)
        + discovered.filter { !knownIds.contains($0.id) }.map(ConnectionRow.discovered)
}
