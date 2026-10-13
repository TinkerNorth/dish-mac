// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// The link-tier ladder: how fast and how stable a kind of host link is,
// ranked best-first. One ladder across the Dish clients, so a user who reads
// "Fastest" beside a satellite on the phone reads the same word beside it
// here. This client speaks only to satellites, so only the top rung is ever
// produced; the others stay so the vocabulary is one ladder and not two that
// happen to agree. Tokens only; the words live in the app.

import Foundation

public enum ConnectionKind: Equatable, Sendable {
    /// Our own wire, one hop, every feature.
    case satellite
    /// A Moonlight host's control stream (Sunshine, Apollo, Wolf).
    case moonlight
    /// The system's Bluetooth gamepad layer.
    case bluetooth
}

/// Declaration order is the ranking: lower is better.
public enum LinkTier: Int, Equatable, Sendable {
    case fastest = 0
    case fast
    case basic
}

public func linkTierFor(_ kind: ConnectionKind) -> LinkTier {
    switch kind {
    case .satellite: .fastest
    case .moonlight: .fast
    case .bluetooth: .basic
    }
}

/// Best-first ordering key for a list that mixes kinds: a smaller rank
/// sorts earlier.
public func linkTierRank(_ tier: LinkTier) -> Int {
    tier.rawValue
}
