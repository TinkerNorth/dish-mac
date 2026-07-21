// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// Tofu — Trust-On-First-Use cert-pinning primitives, pure and IO-free.
//
// The satellite presents a self-signed TLS cert, so there is no CA chain to
// validate. Instead the dish pins the SHA-256 fingerprint of the cert it
// first saw for a given satellite id and, on every later connection, refuses
// any cert whose fingerprint differs (anti-MITM). The verdict ladder + the
// fingerprint hash are the only logic here; storage (which id maps to which
// pin) and the URLSession TLS callback live in the imperative shell. Ports
// dish-linux Network/Tofu.{h,cpp}.

import CryptoKit
import Foundation

/// Outcome of comparing a presented certificate fingerprint to the stored pin.
public enum TofuVerdict: Equatable, Sendable {
    /// No pin stored for this id yet — accept and pin (first contact).
    case trustFirstUse
    /// The presented fingerprint equals the stored one (case-insensitive hex).
    case match
    /// A pin exists and the presented fingerprint differs — reject, keep the pin.
    case mismatch
}

/// Decide the verdict for a presented fingerprint against the stored pin.
///
///     pinned == nil        -> trustFirstUse  (only "never pinned" trusts blindly)
///     equalsIgnoreCase     -> match
///     otherwise            -> mismatch
///
/// An *empty-string* stored pin is a present, non-matching pin: it can
/// mismatch. Only nil means never-pinned.
public func tofuVerdict(pinned: String?, presented: String) -> TofuVerdict {
    guard let pinned else { return .trustFirstUse }
    return equalsIgnoreCaseASCII(pinned, presented) ? .match : .mismatch
}

/// Lowercase 64-char hex SHA-256 of `der` (the cert's DER encoding). Known
/// vectors: "" → e3b0c442…b855, "abc" → ba7816bf…015ad.
public func sha256FingerprintHex(_ der: Data) -> String {
    hexEncodeLower(SHA256.hash(data: der))
}

/// ASCII-only case-insensitive equality (no locale dependence — hex digits
/// and ASCII ids only on this path). Byte-count inequality is an immediate
/// mismatch, exactly like the C++ port.
func equalsIgnoreCaseASCII(_ lhs: String, _ rhs: String) -> Bool {
    let lhsBytes = Array(lhs.utf8)
    let rhsBytes = Array(rhs.utf8)
    guard lhsBytes.count == rhsBytes.count else { return false }
    for (x, y) in zip(lhsBytes, rhsBytes) where lowerASCII(x) != lowerASCII(y) {
        return false
    }
    return true
}

private func lowerASCII(_ byte: UInt8) -> UInt8 {
    byte >= 0x41 && byte <= 0x5A ? byte + 0x20 : byte
}
