// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// A host's names and addresses never leave in the diagnostics file or the
// mail: each becomes "Host 1", "Host 2", by the host's place in the file.

import Foundation

/// "Host 1" for the first host, and so on.
public func hostAlias(_ position: Int) -> String {
    "Host \(position + 1)"
}

struct HostAliasing {
    let name: String
    let alias: String
}

/// Longest first, so a name that contains another is replaced whole.
func hostAliases(_ hostNames: [[String]]) -> [HostAliasing] {
    let pairs = hostNames.enumerated().flatMap { position, names in
        names.filter { !$0.isEmpty }.map { HostAliasing(name: $0, alias: hostAlias(position)) }
    }
    return pairs.sorted { $0.name.count > $1.name.count }
}

/// The text with every name and address of each host, given in the file's
/// order, replaced by that host's alias: the scrub the file's log gets.
public func aliasingHostNames(_ text: String, hostNames: [[String]]) -> String {
    scrub(text, hostAliases(hostNames))
}

func scrub(_ text: String, _ aliases: [HostAliasing]) -> String {
    aliases.reduce(text) { scrubbed, aliasing in scrubbed.replacingOccurrences(of: aliasing.name, with: aliasing.alias) }
}
