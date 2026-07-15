// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// Session-key derivation + REST proof-of-key-possession + UDP packet AEAD —
// byte-for-byte identical to the satellite's net/session_crypto.* so the two
// ends interoperate (satellite/docs/contract.md §Crypto). Pure: Foundation +
// CryptoKit only. The pinned interop vectors are shared with the satellite,
// dish-windows, dish-linux and dish-android session-crypto tests
// (Tests/DishCoreTests/SessionCryptoVectorTests.swift); any drift on any end
// is a cross-end protocol break, not a refactor.
//
// Ports dish-linux src/Network/SessionCrypto.{h,cpp} onto CryptoKit:
//   * HKDF-SHA256 (RFC 5869 extract-then-expand, one 32-byte output block)
//   * HMAC-SHA256 proof, lowercase hex
//   * ChaCha20-Poly1305-IETF with nonce = dir(1) | 0x00×7 | counter(4 BE)
//     and AAD = token(4 BE)

import CryptoKit
import Foundation

/// Nonce direction byte (`nonce[0]`); keeps the two directions of one session
/// key from ever sharing a nonce (contract §Crypto).
public enum WireDirection: UInt8, Sendable {
    /// Client → server (`0x00`).
    case up = 0x00
    /// Server → client (`0x01`).
    case down = 0x01
}

/// Failures `SessionCrypto.open` can produce before CryptoKit even runs.
/// Authentication failures surface as `CryptoKitError` from the AEAD itself.
public enum SessionCryptoError: Error, Equatable {
    /// The box is shorter than a Poly1305 tag — not even an empty message.
    case malformedBox
}

/// The protocol-1 session-crypto primitives. Stateless namespace: counters,
/// replay guards and key storage live in the imperative shell.
public enum SessionCrypto {

    /// `sessionKey = HKDF-SHA256(ikm = pairingKey, salt = sessionSalt,
    /// info = "satellite-session-v1" || token(4 BE))`, 32-byte output.
    ///
    /// Both ends derive the same key from the session PUT response's token +
    /// sessionSalt, so counters restart at 1 with no cross-session nonce
    /// reuse. Per contract the pairing key is 32 bytes and the salt 8 bytes
    /// (`ProtocolConstants.cryptoKeySize` / `.sessionSaltSize`) — the control
    /// plane validates the REST hex before calling. The pairing key itself
    /// NEVER encrypts traffic.
    public static func deriveSessionKey(pairingKey: Data, salt: Data, token: UInt32) -> SymmetricKey {
        var info = Data(hkdfInfoLabel.utf8)
        info.append(contentsOf: bigEndianBytes(token))
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: pairingKey),
            salt: salt,
            info: info,
            outputByteCount: ProtocolConstants.cryptoKeySize
        )
    }

    /// `hex( HMAC-SHA256( pairingKey, "satellite-proof:" + deviceId ) )`,
    /// lowercase — sent in the `X-Hmac-Proof` header on every authenticated
    /// REST call (contract §hmacProof).
    public static func hmacProofHex(pairingKey: Data, deviceId: String) -> String {
        let mac = HMAC<SHA256>.authenticationCode(
            for: proofMessage(deviceId: deviceId),
            using: SymmetricKey(data: pairingKey)
        )
        return hexEncodeLower(mac)
    }

    /// Constant-time verify of a hex proof against `(pairingKey, deviceId)`.
    /// False on malformed hex. Symmetric with the satellite's server-side
    /// check (the client only needs it for tests/tooling, but keeping both
    /// directions here keeps the primitive honest).
    public static func verifyHmacProofHex(pairingKey: Data, deviceId: String, proofHex: String) -> Bool {
        guard let supplied = hexDecode(proofHex), supplied.count == SHA256.byteCount else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(
            supplied,
            authenticating: proofMessage(deviceId: deviceId),
            using: SymmetricKey(data: pairingKey)
        )
    }

    /// AEAD-seal one packet body (ChaCha20-Poly1305-IETF). Returns
    /// ciphertext + 16-byte tag — the `box` that rides after the cleartext
    /// `token|counter` header (`PacketCodec.frame`).
    ///
    /// nonce = `direction(1) | 0x00×7 | counter(4 BE)`; AAD = `token(4 BE)`.
    /// Each direction keeps its own monotonically increasing counter,
    /// starting at 1 (contract §Crypto).
    public static func seal(
        _ plaintext: Data,
        key: SymmetricKey,
        direction: WireDirection,
        counter: UInt32,
        token: UInt32
    ) throws -> Data {
        let sealed = try ChaChaPoly.seal(
            plaintext,
            using: key,
            nonce: ChaChaPoly.Nonce(data: nonceBytes(direction: direction, counter: counter)),
            authenticating: aadBytes(token: token)
        )
        return sealed.ciphertext + sealed.tag
    }

    /// Open one `ciphertext+tag` box sealed by the peer. Throws on any
    /// direction / counter / token mismatch (they are bound into nonce + AAD)
    /// and on tampering — the caller drops the datagram.
    public static func open(
        _ box: Data,
        key: SymmetricKey,
        direction: WireDirection,
        counter: UInt32,
        token: UInt32
    ) throws -> Data {
        guard box.count >= ProtocolConstants.authTagSize else { throw SessionCryptoError.malformedBox }
        let sealed = try ChaChaPoly.SealedBox(
            nonce: ChaChaPoly.Nonce(data: nonceBytes(direction: direction, counter: counter)),
            ciphertext: box.dropLast(ProtocolConstants.authTagSize),
            tag: box.suffix(ProtocolConstants.authTagSize)
        )
        return try ChaChaPoly.open(sealed, using: key, authenticating: aadBytes(token: token))
    }

    /// Constant-time byte comparison (libsodium `sodium_memcmp` analogue) for
    /// secret material the type system doesn't already guard. Length mismatch
    /// returns false immediately — lengths are not secret here.
    public static func constantTimeEquals(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var acc: UInt8 = 0
        for (left, right) in zip(a, b) {
            acc |= left ^ right
        }
        return acc == 0
    }

    // MARK: - Internal layout builders (unit-addressable via the public API)

    /// HKDF info label; the 4-byte big-endian token is appended per session.
    static let hkdfInfoLabel = "satellite-session-v1"

    static func proofMessage(deviceId: String) -> Data {
        Data("satellite-proof:\(deviceId)".utf8)
    }

    static func nonceBytes(direction: WireDirection, counter: UInt32) -> Data {
        var nonce = [UInt8](repeating: 0, count: ProtocolConstants.cryptoNonceSize)
        nonce[0] = direction.rawValue
        nonce[8] = UInt8(truncatingIfNeeded: counter >> 24)
        nonce[9] = UInt8(truncatingIfNeeded: counter >> 16)
        nonce[10] = UInt8(truncatingIfNeeded: counter >> 8)
        nonce[11] = UInt8(truncatingIfNeeded: counter)
        return Data(nonce)
    }

    static func aadBytes(token: UInt32) -> Data {
        Data(bigEndianBytes(token))
    }

    static func bigEndianBytes(_ value: UInt32) -> [UInt8] {
        [
            UInt8(truncatingIfNeeded: value >> 24),
            UInt8(truncatingIfNeeded: value >> 16),
            UInt8(truncatingIfNeeded: value >> 8),
            UInt8(truncatingIfNeeded: value)
        ]
    }
}

// MARK: - Module-internal hex (the app target keeps its own Util/Hex)

/// Lowercase hex encoding of raw bytes.
func hexEncodeLower(_ bytes: some Sequence<UInt8>) -> String {
    let digits = Array("0123456789abcdef")
    var out = ""
    for byte in bytes {
        out.append(digits[Int(byte >> 4)])
        out.append(digits[Int(byte & 0x0F)])
    }
    return out
}

/// Decode a lower- or upper-case hex string; nil on odd length or non-hex
/// characters.
func hexDecode(_ hex: String) -> Data? {
    guard hex.count % 2 == 0 else { return nil }
    var out = Data(capacity: hex.count / 2)
    var index = hex.startIndex
    while index < hex.endIndex {
        let next = hex.index(index, offsetBy: 2)
        guard let byte = UInt8(hex[index ..< next], radix: 16) else { return nil }
        out.append(byte)
        index = next
    }
    return out
}
