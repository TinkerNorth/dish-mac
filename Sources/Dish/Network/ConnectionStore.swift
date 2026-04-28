// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Foundation

/// Persistent registry of remembered connections + per-server shared keys.
/// Backed by `UserDefaults` (the macOS analogue of Android's SharedPreferences).
final class ConnectionStore {

    private let defaults: UserDefaults
    private let deviceIdKey = "deviceId"
    private let wifiListKey = "wifi_list"
    private let sharedKeyPrefix = "wifi_shared_key:"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Device id

    /// Stable per-install device id. Generated once on first launch.
    func getOrCreateDeviceId() -> String {
        if let existing = defaults.string(forKey: deviceIdKey) { return existing }
        let fresh = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        defaults.set(fresh, forKey: deviceIdKey)
        return fresh
    }

    // MARK: - Remembered servers

    func remembered() -> [RememberedWifi] {
        guard let data = defaults.data(forKey: wifiListKey),
              let list = try? JSONDecoder().decode([RememberedWifi].self, from: data) else { return [] }
        return list
    }

    func remember(_ server: DiscoveredServer) {
        let id = server.id
        var list = remembered().filter { $0.id != id }
        list.append(RememberedWifi(
            id: id,
            name: server.name,
            ip: server.ip,
            udpPort: server.udpPort,
            pairPort: server.pairPort,
            httpPort: server.httpPort
        ))
        persist(list)
    }

    func forget(_ id: String) {
        persist(remembered().filter { $0.id != id })
        defaults.removeObject(forKey: sharedKeyPrefix + id)
    }

    private func persist(_ list: [RememberedWifi]) {
        if let data = try? JSONEncoder().encode(list) {
            defaults.set(data, forKey: wifiListKey)
        }
    }

    // MARK: - Per-server shared key (hex)

    func sharedKey(for id: String) -> String? {
        defaults.string(forKey: sharedKeyPrefix + id)
    }

    func setSharedKey(_ keyHex: String, for id: String) {
        defaults.set(keyHex, forKey: sharedKeyPrefix + id)
    }
}
