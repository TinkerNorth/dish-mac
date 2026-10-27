// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// "Keeps disconnecting": a pad that drops three times within a minute gets
// one notice, and no second one until its drops thin out below that rate.
// The caller passes the instant of each drop on any monotonic basis.

import Foundation

public enum DisconnectBurstRule {
    public static let drops = 3
    public static let windowMs: Int64 = 60000
}

public struct DisconnectBursts: Equatable, Sendable {
    /// Each pad identity's drops still inside the window.
    public private(set) var recentDrops: [String: [Int64]] = [:]
    /// The identities whose current burst has had its notice.
    public private(set) var noticed: Set<String> = []

    public init() {}

    /// Records one drop; true when it starts a burst the user should hear about.
    public mutating func recordDrop(_ identity: String, nowMs: Int64) -> Bool {
        let windowStart = nowMs - DisconnectBurstRule.windowMs
        let kept = (recentDrops[identity] ?? []).filter { $0 > windowStart }
        let drops = kept + [nowMs]
        recentDrops[identity] = drops
        let inBurst = drops.count >= DisconnectBurstRule.drops
        guard inBurst else {
            noticed.remove(identity)
            return false
        }
        let alreadyNoticed = noticed.contains(identity)
        noticed.insert(identity)
        return !alreadyNoticed
    }
}
