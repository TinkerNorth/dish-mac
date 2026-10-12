// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Foundation

/// Persistent registry of remembered connections, per-satellite pairing keys
/// and TOFU cert pins. Rows + pins live in `UserDefaults` (the macOS analogue
/// of QSettings / SharedPreferences); pairing keys live in the injected
/// `KeyStore` (Keychain in production — gap G17) with a one-time migration of
/// any keys persisted by pre-protocol-1 builds.
///
/// Identity (contract §Identity, gap G11): rows are keyed on
/// `DiscoveredServer.id` — `mid:<machineId>` when the satellite advertises
/// one, else the legacy `wifi:<ip>:<udpPort>`. Rows persisted before
/// protocol-1 (no machineId) still load and are upgraded in place the first
/// time the box is seen with a stable id (`remember` collapses the legacy
/// ghost and carries its pairing key forward).
///
/// Cert pins are keyed by HOST (IP string) because the TLS layer only knows
/// the URL host at verify time; `remember` migrates the pin when a
/// machineId-matched satellite moves address. Pin accessors are lock-guarded —
/// the TOFU delegate verifies pins from URLSession's delegate queue while the
/// main actor may be writing. Ports dish-linux `Network/ConnectionStore`.
final class ConnectionStore {

    private let defaults: UserDefaults
    private let keyStore: KeyStore
    private let deviceIdKey = "deviceId"
    private let wifiListKey = "wifi_list"
    /// Legacy pairing-key prefix — pre-G17 builds kept keys in UserDefaults.
    /// Still recognized for the one-time migration; never written anymore.
    private let legacySharedKeyPrefix = "wifi_shared_key:"
    private let certPinPrefix = "cert_pin:"
    /// Guards the pin accessors only (see class comment). The remembered-list
    /// accessors stay main-thread-only like before.
    private let pinLock = NSLock()

    init(defaults: UserDefaults = .standard, keyStore: KeyStore = KeychainKeyStore()) {
        self.defaults = defaults
        self.keyStore = keyStore
        migrateLegacyKeys()
    }

    // MARK: - Device id

    /// Stable per-install device id. Generated once on first launch. Not a
    /// secret (it rides every REST call in `X-Device-Id`) — UserDefaults is
    /// the right home; the pairing key is what moved to the Keychain.
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

    /// Remember (insert or refresh) a satellite under its stable id, applying
    /// the protocol-1 identity rules:
    ///
    /// - a discovery result WITHOUT a machineId never mints a fresh row beside
    ///   a stable one — it only refreshes a known stable row at the same
    ///   address;
    /// - a result WITH a machineId collapses any legacy `wifi:` ghost rows at
    ///   the same address, carrying their pairing key forward;
    /// - when a known box comes back under a new IP, its TOFU cert pin
    ///   follows it (`migratePinOnAddressChange`).
    func remember(_ server: DiscoveredServer) {
        if isBlank(server.machineId), refreshKnownBox(server) { return }

        let id = server.id
        if !isBlank(server.machineId) {
            collapseLegacyGhosts(server, stableId: id)
        }

        var list = remembered()
        let oldIp = list.first { $0.id == id }?.ip
        migratePinOnAddressChange(oldIp: oldIp, newIp: server.ip)

        list.removeAll { $0.id == id }
        list.append(RememberedWifi(
            id: id,
            name: server.name,
            ip: server.ip,
            udpPort: server.udpPort,
            pairPort: server.pairPort,
            httpPort: server.httpPort,
            machineId: server.machineId
        ))
        persist(list)
    }

    /// Re-point remembered rows from a fresh discovery scan: a satellite whose
    /// machineId matches a remembered row (or that upgrades a legacy ip:port
    /// row) gets its endpoint refreshed IN PLACE, so auto-reconnect targets
    /// the current address after a DHCP move — no manual re-add. Never adds a
    /// new satellite. Ports dish-linux `refreshFromDiscovery`.
    func refreshFromDiscovery(_ discovered: [DiscoveredServer]) {
        let rows = remembered()
        let knownIds = Set(rows.map(\.id))

        for server in discovered {
            // A result without a machineId never re-points a remembered row.
            if isBlank(server.machineId) { continue }
            var eligible = knownIds.contains(server.id)
            if !eligible {
                // Or a legacy ip:port row this stable server is the upgrade of.
                eligible = rows.contains { row in
                    isBlank(row.machineId) && row.ip == server.ip && row.udpPort == server.udpPort
                }
            }
            if eligible { remember(server) }
        }
    }

    func forget(_ id: String) {
        var list = remembered()
        // Pin is keyed by IP; drop it via the row's IP before the row goes.
        if let row = list.first(where: { $0.id == id }) {
            forgetCertPin(host: row.ip)
        }
        list.removeAll { $0.id == id }
        persist(list)
        keyStore.removePairingKey(for: id)
    }

    private func persist(_ list: [RememberedWifi]) {
        if let data = try? JSONEncoder().encode(list) {
            defaults.set(data, forKey: wifiListKey)
        }
    }

    // MARK: - remember() helpers (see dish-linux ConnectionStore for the origin of each rule)

    /// The server advertised no machineId. Find an existing STABLE row (one
    /// that DID advertise one) at the same address and refresh its name +
    /// ports in place — don't mint an ip:port ghost beside it.
    private func refreshKnownBox(_ server: DiscoveredServer) -> Bool {
        var list = remembered()
        for (index, row) in list.enumerated()
            where !isBlank(row.machineId) && row.ip == server.ip && row.udpPort == server.udpPort
        {
            var refreshed = row
            refreshed.name = server.name
            refreshed.pairPort = server.pairPort
            refreshed.httpPort = server.httpPort
            if refreshed != row {
                list[index] = refreshed
                persist(list)
            }
            return true
        }
        return false
    }

    /// The box just gained a stable id. For every legacy row (no machineId)
    /// at the same address: carry its pairing key forward to the stable id
    /// (the stable row's own key wins if it already has one), then drop the
    /// ghost's key + row.
    private func collapseLegacyGhosts(_ server: DiscoveredServer, stableId: String) {
        var list = remembered()
        var changed = false
        for row in list
            where isBlank(row.machineId) && row.ip == server.ip && row.udpPort == server.udpPort
        {
            if sharedKey(for: stableId) == nil, let ghostKey = sharedKey(for: row.id) {
                setSharedKey(ghostKey, for: stableId)
            }
            keyStore.removePairingKey(for: row.id)
            changed = true
        }
        if changed {
            list.removeAll { row in
                isBlank(row.machineId) && row.ip == server.ip && row.udpPort == server.udpPort
            }
            persist(list)
        }
    }

    /// The cert pin follows the box (pin keyed by IP). A pin already trusted
    /// at the new address is NOT overwritten; the old-address pin is ALWAYS
    /// dropped.
    private func migratePinOnAddressChange(oldIp: String?, newIp: String) {
        guard let oldIp, oldIp != newIp else { return }
        if certPin(host: newIp) == nil, let oldPin = certPin(host: oldIp) {
            setCertPin(host: newIp, fingerprintHex: oldPin)
        }
        forgetCertPin(host: oldIp)
    }

    private func isBlank(_ string: String) -> Bool {
        string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Per-satellite pairing key (hex, Keychain-backed)

    func sharedKey(for id: String) -> String? {
        keyStore.pairingKeyHex(for: id)
    }

    func setSharedKey(_ keyHex: String, for id: String) {
        keyStore.setPairingKeyHex(keyHex, for: id)
    }

    /// Drop only the pairing key (terminal 401 / close-notify(unpaired)): the
    /// row survives so the UI can park it on "Needs pairing".
    func forgetKey(for id: String) {
        keyStore.removePairingKey(for: id)
    }

    /// One-time migration of pairing keys persisted in UserDefaults by
    /// pre-G17 builds. Each key is copied into the KeyStore and removed from
    /// defaults only when the store accepted the write (a refused Keychain
    /// never loses the only copy). An existing KeyStore entry wins — defaults
    /// can't downgrade a newer key.
    private func migrateLegacyKeys() {
        for (key, value) in defaults.dictionaryRepresentation() where key.hasPrefix(legacySharedKeyPrefix) {
            guard let keyHex = value as? String, !keyHex.isEmpty else {
                defaults.removeObject(forKey: key)
                continue
            }
            let id = String(key.dropFirst(legacySharedKeyPrefix.count))
            let accepted = keyStore.pairingKeyHex(for: id) != nil
                || keyStore.setPairingKeyHex(keyHex, for: id)
            if accepted {
                defaults.removeObject(forKey: key)
            }
        }
    }

    // MARK: - TOFU cert pins (SHA-256 fingerprint hex, keyed by host/IP)

    /// The stored pin for `host`, or nil when never pinned. An empty string
    /// is normalized away at write time, so nil is the only "never pinned"
    /// signal (`tofuVerdict` treats an empty stored pin as a real pin).
    func certPin(host: String) -> String? {
        pinLock.lock()
        defer { pinLock.unlock() }
        return defaults.string(forKey: certPinPrefix + host)
    }

    func setCertPin(host: String, fingerprintHex: String) {
        pinLock.lock()
        defer { pinLock.unlock() }
        // Writing an empty pin clears instead — keeps "nil = never pinned"
        // the single source of truth, matching the dish-linux store's
        // observable behavior (QSettings can't tell "" from absent).
        if fingerprintHex.isEmpty {
            defaults.removeObject(forKey: certPinPrefix + host)
        } else {
            defaults.set(fingerprintHex, forKey: certPinPrefix + host)
        }
    }

    func forgetCertPin(host: String) {
        pinLock.lock()
        defer { pinLock.unlock() }
        defaults.removeObject(forKey: certPinPrefix + host)
    }
}
