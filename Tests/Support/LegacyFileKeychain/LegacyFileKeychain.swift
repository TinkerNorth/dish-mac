// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// The one place the test suite touches the legacy SecKeychain API, compiled
// with `-suppress-warnings` (see Package.swift). Marker: the right fix is a
// non-deprecated way to assemble a `SecIdentity` for a headless TLS listener,
// which macOS does not offer. A key must be born inside a keychain for
// `SecIdentityCreateWithCertificate` to match it, the data-protection keychain
// needs an entitlement an unsigned `swift test` runner cannot carry, and the
// login keychain would prompt and leak test material into the user's own
// keychain. A throwaway file keychain in the temporary directory is the one
// prompt-free route, and `SecKeychainCreate` is its only constructor.

import Foundation
import Security

/// Create a throwaway file keychain at `path`, unlocked with `phrase`.
/// Nil when the system refuses (a locked-down runner): callers fall back to
/// an identity-less certificate.
public func createLegacyFileKeychain(at path: String, phrase: String) -> SecKeychain? {
    var created: SecKeychain?
    let status = phrase.withCString { phraseBytes in
        SecKeychainCreate(path, UInt32(phrase.utf8.count), phraseBytes, false, nil, &created)
    }
    guard status == errSecSuccess else { return nil }
    return created
}
