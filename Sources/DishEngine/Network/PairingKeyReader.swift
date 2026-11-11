// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Foundation

/// The control plane's reads of the pairing keys, on a queue of their own.
/// A Keychain read of a key that another build saved waits until the user
/// answers macOS's access prompt (every ad-hoc build, a release included,
/// has its own code hash), and that wait must never be the main actor's.
final class PairingKeyReader: Sendable {
    private let keyStore: KeyStore
    private let queue = DispatchQueue(label: "com.tinkernorth.dish.pairing-keys", qos: .userInitiated)

    init(keyStore: KeyStore) {
        self.keyStore = keyStore
    }

    /// The stored key as hex, or nil when absent or unreadable.
    func pairingKeyHex(for id: String) async -> String? {
        await withCheckedContinuation { continuation in read(id, answering: continuation) }
    }

    private func read(_ id: String, answering continuation: CheckedContinuation<String?, Never>) {
        queue.async { [keyStore] in continuation.resume(returning: keyStore.pairingKeyHex(for: id)) }
    }
}
