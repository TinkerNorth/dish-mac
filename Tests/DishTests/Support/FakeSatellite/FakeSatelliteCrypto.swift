// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// Independent protocol-1 session crypto for the FakeSatellite test harness,
// written directly against `satellite/docs/contract.md` §Crypto.
//
// DELIBERATELY not the app implementation, and it must never import DishCore:
// the harness double-checks the app's crypto byte-for-byte in integration
// tests, which only works if the two sides share no code. The self-test suite
// (FakeSatelliteSelfTests) pins this implementation to the same cross-repo
// interop vectors the satellite, dish-linux, dish-windows and dish-android
// test suites assert.

import CryptoKit
import Foundation

enum FakeSatelliteCrypto {

    /// AEAD nonce direction byte (contract §Packet format).
    enum Direction: UInt8 {
        case clientToServer = 0x00
        case serverToClient = 0x01
    }

    enum Failure: Error {
        case malformedBox
    }

    /// contract §Crypto: info = "satellite-session-v1" || token(4 bytes BE).
    static let sessionInfoPrefix = "satellite-session-v1"
    /// contract §hmacProof: message = "satellite-proof:" + deviceId.
    static let proofMessagePrefix = "satellite-proof:"
    /// ChaCha20-Poly1305 tag appended to every ciphertext box.
    static let tagSize = 16

    // MARK: - Hex helpers

    static func hexString(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    static func hexToData(_ hex: String) -> Data? {
        let digits = Array(hex.lowercased().utf8)
        guard digits.count.isMultiple(of: 2) else { return nil }
        var out = Data(capacity: digits.count / 2)
        var index = 0
        while index < digits.count {
            guard let high = nibble(digits[index]), let low = nibble(digits[index + 1]) else { return nil }
            out.append(high << 4 | low)
            index += 2
        }
        return out
    }

    private static func nibble(_ char: UInt8) -> UInt8? {
        switch char {
        case 0x30 ... 0x39: char - 0x30
        case 0x61 ... 0x66: char - 0x61 + 10
        default: nil
        }
    }

    // MARK: - Endian helpers (wire scalars are BE; telemetry payloads are LE)

    static func be32(_ value: UInt32) -> Data {
        Data([
            UInt8(truncatingIfNeeded: value >> 24),
            UInt8(truncatingIfNeeded: value >> 16),
            UInt8(truncatingIfNeeded: value >> 8),
            UInt8(truncatingIfNeeded: value)
        ])
    }

    static func be16(_ value: UInt16) -> Data {
        Data([UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)])
    }

    static func tokenBE(_ token: UInt32) -> Data {
        be32(token)
    }

    static func readBE32(_ data: Data, at offset: Int) -> UInt32 {
        let base = data.startIndex + offset
        return UInt32(data[base]) << 24 | UInt32(data[base + 1]) << 16 | UInt32(data[base + 2]) << 8 | UInt32(data[base + 3])
    }

    static func readBE16(_ data: Data, at offset: Int) -> UInt16 {
        let base = data.startIndex + offset
        return UInt16(data[base]) << 8 | UInt16(data[base + 1])
    }

    static func readLE16(_ data: Data, at offset: Int) -> UInt16 {
        let base = data.startIndex + offset
        return UInt16(data[base]) | UInt16(data[base + 1]) << 8
    }

    static func readLE32(_ data: Data, at offset: Int) -> UInt32 {
        let base = data.startIndex + offset
        return UInt32(data[base]) | UInt32(data[base + 1]) << 8 | UInt32(data[base + 2]) << 16 | UInt32(data[base + 3]) << 24
    }

    // MARK: - hmacProof (contract §hmacProof)

    static func hmacProofHex(pairingKey: Data, deviceId: String) -> String {
        let message = Data((proofMessagePrefix + deviceId).utf8)
        let mac = HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: pairingKey))
        return hexString(Data(mac))
    }

    /// Constant-time proof verification (CryptoKit's MAC validation compares
    /// in constant time); malformed hex or a wrong-length proof is false.
    static func verifyHmacProof(pairingKey: Data, deviceId: String, proofHex: String) -> Bool {
        guard let presented = hexToData(proofHex), presented.count == SHA256.Digest.byteCount else { return false }
        let message = Data((proofMessagePrefix + deviceId).utf8)
        return HMAC<SHA256>.isValidAuthenticationCode(presented, authenticating: message, using: SymmetricKey(data: pairingKey))
    }

    /// Constant-time equality for non-MAC comparisons (length leaks, bytes do not).
    static func constantTimeEquals(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for offset in 0 ..< lhs.count {
            difference |= lhs[lhs.startIndex + offset] ^ rhs[rhs.startIndex + offset]
        }
        return difference == 0
    }

    // MARK: - Session key (contract §Crypto)

    /// sessionKey = HKDF-SHA256(ikm: pairingKey, salt: 8-byte sessionSalt,
    /// info: "satellite-session-v1" || token(4 BE)), one 32-byte block.
    static func deriveSessionKey(pairingKey: Data, salt: Data, token: UInt32) -> SymmetricKey {
        var info = Data(sessionInfoPrefix.utf8)
        info.append(tokenBE(token))
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: pairingKey),
            salt: salt,
            info: info,
            outputByteCount: 32
        )
    }

    static func keyData(_ key: SymmetricKey) -> Data {
        key.withUnsafeBytes { Data($0) }
    }

    // MARK: - Packet AEAD (contract §Packet format)

    /// nonce (12 bytes) = dir(1) | 0x00 × 7 | counter(4 BE).
    static func nonceData(direction: Direction, counter: UInt32) -> Data {
        Data([direction.rawValue, 0, 0, 0, 0, 0, 0, 0]) + be32(counter)
    }

    /// Seals an inner frame. Returns ciphertext || tag (the datagram "box");
    /// AAD is the token, so the cleartext header is tamper-evident.
    static func seal(_ plaintext: Data, key: SymmetricKey, direction: Direction, counter: UInt32, token: UInt32) throws -> Data {
        let nonce = try ChaChaPoly.Nonce(data: nonceData(direction: direction, counter: counter))
        let box = try ChaChaPoly.seal(plaintext, using: key, nonce: nonce, authenticating: tokenBE(token))
        return box.ciphertext + box.tag
    }

    /// Opens a ciphertext || tag box; throws on any authentication failure
    /// (wrong key, direction, counter or token — all are nonce/AAD-bound).
    static func open(_ box: Data, key: SymmetricKey, direction: Direction, counter: UInt32, token: UInt32) throws -> Data {
        guard box.count >= tagSize else { throw Failure.malformedBox }
        let nonce = try ChaChaPoly.Nonce(data: nonceData(direction: direction, counter: counter))
        let sealed = try ChaChaPoly.SealedBox(nonce: nonce, ciphertext: box.dropLast(tagSize), tag: box.suffix(tagSize))
        return try ChaChaPoly.open(sealed, using: key, authenticating: tokenBE(token))
    }

    // MARK: - Wire framing (cleartext header + inner frame)

    struct DatagramHeader {
        let token: UInt32
        let counter: UInt32
        let box: Data
    }

    /// datagram = token(4 BE) | counter(4 BE) | box.
    static func sealDatagram(inner: Data, key: SymmetricKey, direction: Direction, counter: UInt32, token: UInt32) throws -> Data {
        try tokenBE(token) + be32(counter) + seal(inner, key: key, direction: direction, counter: counter, token: token)
    }

    /// Splits the cleartext header off a datagram (no crypto involved).
    static func parseDatagram(_ raw: Data) -> DatagramHeader? {
        guard raw.count >= 8 + tagSize else { return nil }
        return DatagramHeader(token: readBE32(raw, at: 0), counter: readBE32(raw, at: 4), box: raw.dropFirst(8))
    }

    /// inner plaintext = msgType(2 BE) | msgLen(2 BE) | payload.
    static func encodeInner(msgType: UInt16, payload: Data) -> Data {
        be16(msgType) + be16(UInt16(truncatingIfNeeded: payload.count)) + payload
    }

    /// Honors `msgLen` like the real receiver: an inner frame whose declared
    /// length overruns the plaintext is dropped, and trailing bytes beyond
    /// `msgLen` are sliced off.
    static func parseInner(_ inner: Data) -> (msgType: UInt16, payload: Data)? {
        guard inner.count >= 4 else { return nil }
        let msgLen = Int(readBE16(inner, at: 2))
        guard 4 + msgLen <= inner.count else { return nil }
        return (readBE16(inner, at: 0), inner.dropFirst(4).prefix(msgLen))
    }
}
