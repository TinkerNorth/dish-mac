// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// "Check for controller updates automatically", on by default, and what the
// last check left behind: when it ran, what it found, and the manifest's
// ETag for the next `If-None-Match`.

import DishCore
import DishKernel
import Foundation

@MainActor
package final class ControllerDbPreferenceStore: StateSource<Bool> {
    static let checksEnabledKey = "controller_db_check_enabled"
    static let lastCheckKey = "controller_db_last_check_utc_ms"
    static let lastResultKey = "controller_db_last_check_result"
    static let etagKey = "controller_db_manifest_etag"

    private let defaults: UserDefaults

    package init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        super.init(initial: defaults.object(forKey: Self.checksEnabledKey) as? Bool ?? true)
    }

    package func setChecksEnabled(_ enabled: Bool) {
        guard enabled != state else { return }
        defaults.set(enabled, forKey: Self.checksEnabledKey)
        setState(enabled)
    }

    var lastCheckMs: Int64? {
        (defaults.object(forKey: Self.lastCheckKey) as? Int).map(Int64.init)
    }

    var lastResult: ControllerDbCheckResult? {
        defaults.string(forKey: Self.lastResultKey).flatMap(ControllerDbCheckResult.init(rawValue:))
    }

    var etag: String? {
        defaults.string(forKey: Self.etagKey)
    }

    func recordCheck(_ result: ControllerDbCheckResult, atMs: Int64) {
        defaults.set(Int(atMs), forKey: Self.lastCheckKey)
        defaults.set(result.rawValue, forKey: Self.lastResultKey)
    }

    func setEtag(_ etag: String?) {
        defaults.set(etag, forKey: Self.etagKey)
    }
}
