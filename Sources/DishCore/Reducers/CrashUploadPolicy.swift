// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// Whether a crash report may leave this Mac, as a pure rule: the build has
// to carry a reporting address and the user has to have left the switch on.
// Neither alone is enough, and the switch is checked first, so no address,
// compiled in or not, is a way to report from a machine whose owner turned
// this off. The same rule the other clients apply.

import Foundation

public enum CrashUploadPolicy {
    /// The fleet's key for the switch, kept so a report of one client's
    /// preferences reads like another's.
    public static let enabledKey = "crashlytics_collection_enabled"
    /// On by default, as on every other client; the policy says so.
    public static let defaultEnabled = true
    public static let product = "dish-mac"

    public static func shouldArm(dsn: String?, userEnabled: Bool) -> Bool {
        guard userEnabled else { return false }
        return carriesAddress(dsn)
    }

    public static func carriesAddress(_ dsn: String?) -> Bool {
        guard let dsn else { return false }
        return !dsn.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// "production" when an address is compiled in, "development" otherwise:
    /// derived from the address, so the label cannot drift from the thing
    /// that decides whether anything is sent.
    public static func environment(dsn: String?) -> String {
        carriesAddress(dsn) ? "production" : "development"
    }

    /// The release a report names, the fleet's shape: `dish-mac@1.2.3`.
    public static func release(version: String) -> String {
        "\(product)@\(version)"
    }
}
