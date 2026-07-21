// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// G17: pairing keys live behind the KeyStore seam — Keychain in production,
// in-memory for tests/CI — with a one-time migration out of UserDefaults.

import XCTest
@testable import Dish

final class KeyStoreTests: XCTestCase {

    private func makeDefaults() -> (UserDefaults, String) {
        let name = "dish.test.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: name) else {
            preconditionFailure("could not create isolated UserDefaults test suite")
        }
        return (defaults, name)
    }

    // MARK: - InMemoryKeyStore contract

    func testInMemoryRoundTrip() {
        let store = InMemoryKeyStore()
        XCTAssertNil(store.pairingKeyHex(for: "mid:a"))
        XCTAssertTrue(store.setPairingKeyHex("aa11", for: "mid:a"))
        XCTAssertEqual(store.pairingKeyHex(for: "mid:a"), "aa11")
        store.setPairingKeyHex("bb22", for: "mid:a")
        XCTAssertEqual(store.pairingKeyHex(for: "mid:a"), "bb22")
        store.removePairingKey(for: "mid:a")
        XCTAssertNil(store.pairingKeyHex(for: "mid:a"))
        // Removing an absent key is a no-op, not a crash.
        store.removePairingKey(for: "mid:a")
    }

    func testInMemoryKeysAreIsolatedPerId() {
        let store = InMemoryKeyStore()
        store.setPairingKeyHex("aa", for: "mid:a")
        store.setPairingKeyHex("bb", for: "wifi:1.2.3.4:9876")
        XCTAssertEqual(store.pairingKeyHex(for: "mid:a"), "aa")
        XCTAssertEqual(store.pairingKeyHex(for: "wifi:1.2.3.4:9876"), "bb")
        store.removePairingKey(for: "mid:a")
        XCTAssertEqual(store.pairingKeyHex(for: "wifi:1.2.3.4:9876"), "bb")
    }

    // MARK: - KeychainKeyStore (skips when the environment refuses Keychain writes)

    func testKeychainRoundTripWhenAvailable() throws {
        let store = KeychainKeyStore()
        // Unique account so parallel/repeated runs never collide; always
        // cleaned up.
        let id = "dish-test:\(UUID().uuidString)"
        defer { store.removePairingKey(for: id) }

        guard store.setPairingKeyHex("cafe01", for: id) else {
            throw XCTSkip("Keychain refused the write in this environment (headless CI?)")
        }
        XCTAssertEqual(store.pairingKeyHex(for: id), "cafe01")
        // Second write must replace, not duplicate.
        XCTAssertTrue(store.setPairingKeyHex("cafe02", for: id))
        XCTAssertEqual(store.pairingKeyHex(for: id), "cafe02")
        store.removePairingKey(for: id)
        XCTAssertNil(store.pairingKeyHex(for: id))
    }

    // MARK: - UserDefaults → KeyStore migration (ConnectionStore.init)

    func testLegacyDefaultsKeysMigrateIntoKeyStore() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("11aa", forKey: "wifi_shared_key:wifi:1.2.3.4:9876")
        defaults.set("22bb", forKey: "wifi_shared_key:mid:m-1")

        let keyStore = InMemoryKeyStore()
        let store = ConnectionStore(defaults: defaults, keyStore: keyStore)

        XCTAssertEqual(store.sharedKey(for: "wifi:1.2.3.4:9876"), "11aa")
        XCTAssertEqual(store.sharedKey(for: "mid:m-1"), "22bb")
        // The plaintext copies are gone from defaults.
        XCTAssertNil(defaults.string(forKey: "wifi_shared_key:wifi:1.2.3.4:9876"))
        XCTAssertNil(defaults.string(forKey: "wifi_shared_key:mid:m-1"))
    }

    func testMigrationNeverDowngradesExistingKeyStoreEntry() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("stale-old", forKey: "wifi_shared_key:mid:m-2")

        let keyStore = InMemoryKeyStore()
        keyStore.setPairingKeyHex("fresh-new", for: "mid:m-2")
        let store = ConnectionStore(defaults: defaults, keyStore: keyStore)

        XCTAssertEqual(store.sharedKey(for: "mid:m-2"), "fresh-new")
        // The legacy copy is still cleaned up (the KeyStore already had a key).
        XCTAssertNil(defaults.string(forKey: "wifi_shared_key:mid:m-2"))
    }

    func testMigrationIsIdempotentAcrossRelaunches() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("11aa", forKey: "wifi_shared_key:mid:m-3")

        let keyStore = InMemoryKeyStore()
        _ = ConnectionStore(defaults: defaults, keyStore: keyStore)
        // Second launch over the same defaults+keystore: nothing to migrate,
        // nothing lost.
        let second = ConnectionStore(defaults: defaults, keyStore: keyStore)
        XCTAssertEqual(second.sharedKey(for: "mid:m-3"), "11aa")
    }

    /// A refused KeyStore write must NOT delete the only copy of the key.
    func testMigrationKeepsDefaultsCopyWhenKeyStoreRefuses() {
        final class RefusingKeyStore: KeyStore {
            func pairingKeyHex(for id: String) -> String? {
                nil
            }

            func setPairingKeyHex(_ keyHex: String, for id: String) -> Bool {
                false
            }

            func removePairingKey(for id: String) {}
        }
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("11aa", forKey: "wifi_shared_key:mid:m-4")

        _ = ConnectionStore(defaults: defaults, keyStore: RefusingKeyStore())
        XCTAssertEqual(defaults.string(forKey: "wifi_shared_key:mid:m-4"), "11aa")
    }
}
