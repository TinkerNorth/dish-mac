// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Foundation

/// How a satellite's controller indices are handed out. A session carries
/// up to four pads, the desktops' "slot n of 4" (the satellite itself
/// allows sixteen); each bound pad holds the lowest index free when it
/// bound, and keeps it until it lets go.
public enum SatelliteSlots {
    public static let maxPerSatellite = 4

    /// The lowest index no bound pad holds, or nil when the satellite is full.
    public static func lowestFreeIndex(taken: Set<Int>) -> Int? {
        (0 ..< maxPerSatellite).first { !taken.contains($0) }
    }
}
