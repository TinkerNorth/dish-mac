// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// Pairing-key storage seam (PLAN D3 / gap G17). The 32-byte pairing key is
// the long-lived trust root of the whole protocol — it must not live in
// UserDefaults (world-readable plist on disk). Production uses the macOS
// Keychain; tests and headless CI inject the in-memory implementation.
// `ConnectionStore` owns the one-time UserDefaults → KeyStore migration.

import Foundation
import os
import Security

/// Storage for per-satellite pairing keys (64-char hex), keyed by the stable
/// satellite id (`mid:<machineId>` / legacy `wifi:<ip>:<port>`).
///
/// Implementations must be safe to call from any thread — the manager calls
/// on the main actor, tests from XCTest queues.
protocol KeyStore {
    /// The stored key, or nil when absent (or unreadable).
    func pairingKeyHex(for id: String) -> String?
    /// Persist (insert or replace) a key. Returns false when the backing
    /// store refused the write — callers that DELETE a fallback copy must
    /// only do so on success.
    @discardableResult
    func setPairingKeyHex(_ keyHex: String, for id: String) -> Bool
    /// Drop a key. Removing an absent key is a no-op.
    func removePairingKey(for id: String)
}

/// Keychain-backed production store: one `kSecClassGenericPassword` item per
/// satellite, service-scoped so the items are recognizably ours in Keychain
/// Access. Uses the login keychain (no data-protection flag): the app is not
/// sandboxed/entitled, and generic-password items created by this app are
/// readable by it without a user prompt.
final class KeychainKeyStore: KeyStore {

    /// `kSecAttrService` value for every item this store owns.
    static let service = "com.tinkernorth.dish.pairing-key"

    private static let log = Logger(subsystem: "com.tinkernorth.dish", category: "keystore")

    func pairingKeyHex(for id: String) -> String? {
        var query = baseQuery(for: id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else {
            if status != errSecItemNotFound {
                Self.log.error("keychain read failed (\(status, privacy: .public))")
            }
            return nil
        }
        guard let data = item as? Data, let hex = String(data: data, encoding: .utf8),
              !hex.isEmpty else { return nil }
        return hex
    }

    @discardableResult
    func setPairingKeyHex(_ keyHex: String, for id: String) -> Bool {
        let payload = Data(keyHex.utf8)
        var add = baseQuery(for: id)
        add[kSecValueData as String] = payload
        var status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecDuplicateItem {
            status = SecItemUpdate(
                baseQuery(for: id) as CFDictionary,
                [kSecValueData as String: payload] as CFDictionary
            )
        }
        if status != errSecSuccess {
            Self.log.error("keychain write failed (\(status, privacy: .public))")
        }
        return status == errSecSuccess
    }

    func removePairingKey(for id: String) {
        let status = SecItemDelete(baseQuery(for: id) as CFDictionary)
        if status != errSecSuccess, status != errSecItemNotFound {
            Self.log.error("keychain delete failed (\(status, privacy: .public))")
        }
    }

    private func baseQuery(for id: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: id
        ]
    }
}

/// In-memory store for tests and headless CI (PLAN D3): same contract, no
/// Keychain dependency, thread-safe.
final class InMemoryKeyStore: KeyStore, @unchecked Sendable {
    private var keys: [String: String] = [:]
    private let lock = NSLock()

    func pairingKeyHex(for id: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return keys[id]
    }

    @discardableResult
    func setPairingKeyHex(_ keyHex: String, for id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        keys[id] = keyHex
        return true
    }

    func removePairingKey(for id: String) {
        lock.lock()
        defer { lock.unlock() }
        keys.removeValue(forKey: id)
    }
}
