// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import Foundation

/// Moonlight hosts on the LAN: Sunshine, Apollo and Wolf advertise
/// `_nvstream._tcp`. The SRV port is not the HTTP port, so it is ignored
/// and the documented defaults stand until /serverinfo names the real ones.
/// A typed address is the fallback for a host that advertises nothing.
enum MoonlightDiscovery {
    /// The trailing dot is required by `NWBrowser`.
    static let serviceType = MoonlightProtocol.bonjourType + "."
    static let defaultTimeoutMs = 4000

    static func discover(timeoutMs: Int = defaultTimeoutMs) async -> [MoonlightHost] {
        let outcome = await BonjourScan.discover(serviceType: serviceType, txtKeys: [], timeoutMs: timeoutMs) { name, host, _ in
            let found = MoonlightHost(name: name.isEmpty ? host : name, address: host)
            return (found.id, found)
        }
        return outcome.found
    }
}
