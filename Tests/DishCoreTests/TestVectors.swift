// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// Shared helpers for the DishCore test suites. The interop key here is the
// SAME shared vector key all sibling repos use — see
// SessionCryptoVectorTests.swift for the cross-repo pinning rules.

import CryptoKit
import Foundation

/// Decode a hex literal used in a test vector. Traps on malformed input —
/// a bad vector is a broken test, not a runtime condition.
func hexData(_ hex: String) -> Data {
    precondition(hex.count % 2 == 0, "test vector hex must have even length")
    var out = Data(capacity: hex.count / 2)
    var index = hex.startIndex
    while index < hex.endIndex {
        let next = hex.index(index, offsetBy: 2)
        guard let byte = UInt8(hex[index ..< next], radix: 16) else {
            preconditionFailure("test vector hex contains a non-hex character")
        }
        out.append(byte)
        index = next
    }
    return out
}

/// Lowercase hex of raw bytes (test-side mirror; independent of the module's
/// internal encoder so the vectors don't assert an implementation against
/// itself).
func hexString(_ data: Data) -> String {
    data.map { String(format: "%02x", $0) }.joined()
}

/// pairingKey = 01 02 .. 20 — the shared interop key all ends use.
func interopKey() -> Data {
    Data((1 ... 32).map { UInt8($0) })
}

/// The raw 32 bytes of a CryptoKit symmetric key, for hex comparison.
func keyBytes(_ key: SymmetricKey) -> Data {
    key.withUnsafeBytes { Data($0) }
}
