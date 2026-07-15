// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// Pins DishCore session crypto to the SAME interop vectors as satellite /
// dish-windows / dish-linux / dish-android — any drift is a cross-end
// protocol break, not a refactor. Sources: satellite
// tests/test_windows_platform.cpp, dish-linux tests/test_session_crypto.cpp,
// dish-windows test_session_crypto.cpp, dish-android SessionCryptoTest.

import CryptoKit
import DishCore
import XCTest

final class SessionCryptoVectorTests: XCTestCase {

    // MARK: - hmacProof (contract §hmacProof)

    func testHmacProofMatchesThePinnedInteropVector() {
        let proof = SessionCrypto.hmacProofHex(pairingKey: interopKey(), deviceId: "device-1")
        XCTAssertEqual(proof, "05a035a10c55fdfe254c9df5df55a614ac128b123a5de225ea33b41f1d4eedde")
        XCTAssertEqual(proof.count, 64)
    }

    func testHmacProofIsDeviceBoundAndKeyBound() {
        let key = interopKey()
        let proof1 = SessionCrypto.hmacProofHex(pairingKey: key, deviceId: "device-1")
        XCTAssertNotEqual(SessionCrypto.hmacProofHex(pairingKey: key, deviceId: "device-2"), proof1)
        var other = key
        other[0] = 0x7F
        XCTAssertNotEqual(SessionCrypto.hmacProofHex(pairingKey: other, deviceId: "device-1"), proof1)
    }

    func testVerifyHmacProofAcceptsAMatchingProofAndRejectsTampering() {
        let key = interopKey()
        let proof1 = SessionCrypto.hmacProofHex(pairingKey: key, deviceId: "device-1")
        XCTAssertTrue(SessionCrypto.verifyHmacProofHex(pairingKey: key, deviceId: "device-1", proofHex: proof1))
        // Wrong device id.
        XCTAssertFalse(SessionCrypto.verifyHmacProofHex(pairingKey: key, deviceId: "device-2", proofHex: proof1))
        // Diverged key.
        var other = key
        other[0] ^= 0xFF
        XCTAssertFalse(SessionCrypto.verifyHmacProofHex(pairingKey: other, deviceId: "device-1", proofHex: proof1))
        // Malformed hex.
        XCTAssertFalse(SessionCrypto.verifyHmacProofHex(pairingKey: key, deviceId: "device-1", proofHex: ""))
        XCTAssertFalse(SessionCrypto.verifyHmacProofHex(pairingKey: key, deviceId: "device-1", proofHex: "abc"))
        var bad = proof1
        bad.replaceSubrange(bad.startIndex ... bad.startIndex, with: "z")
        XCTAssertFalse(SessionCrypto.verifyHmacProofHex(pairingKey: key, deviceId: "device-1", proofHex: bad))
    }

    // MARK: - HKDF session key (contract §Crypto)

    func testDeriveSessionKeyMatchesThePinnedHkdfInteropVector() {
        let salt = hexData("a1b2c3d4e5f60718")
        let key = SessionCrypto.deriveSessionKey(pairingKey: interopKey(), salt: salt, token: 0x1234_5678)
        XCTAssertEqual(
            hexString(keyBytes(key)),
            "946f704cf07e2dde5e9995a70d3d103753b4687a7ed9656bc6481b06065a8584"
        )
    }

    func testDeriveSessionKeyIsDeterministicNeverTheRawKeyAndVariesWithInputs() {
        let pairing = interopKey()
        let salt = hexData("a1b2c3d4e5f60718")
        let key1 = SessionCrypto.deriveSessionKey(pairingKey: pairing, salt: salt, token: 0x1234_5678)
        let key2 = SessionCrypto.deriveSessionKey(pairingKey: pairing, salt: salt, token: 0x1234_5678)
        // Deterministic.
        XCTAssertEqual(keyBytes(key1), keyBytes(key2))
        // Never the raw pairing key.
        XCTAssertNotEqual(keyBytes(key1), pairing)
        // The token changes the key.
        let tokenVariant = SessionCrypto.deriveSessionKey(pairingKey: pairing, salt: salt, token: 0x1234_5679)
        XCTAssertNotEqual(keyBytes(key1), keyBytes(tokenVariant))
        // The salt changes the key.
        let saltVariant = SessionCrypto.deriveSessionKey(
            pairingKey: pairing,
            salt: hexData("a1b2c3d4e5f60719"),
            token: 0x1234_5678
        )
        XCTAssertNotEqual(keyBytes(key1), keyBytes(saltVariant))
    }

    // MARK: - Packet AEAD (contract §Crypto packet format)

    /// A heartbeat inner frame: type(2 BE) | len(2 BE) | (empty payload).
    private let heartbeatInner = Data([0x00, 0x02, 0x00, 0x00])

    private func testKey(firstBytes: [UInt8]) -> SymmetricKey {
        var raw = [UInt8](repeating: 0, count: 32)
        for (offset, byte) in firstBytes.enumerated() {
            raw[offset] = byte
        }
        return SymmetricKey(data: Data(raw))
    }

    func testPacketAeadRoundTripsAndTheDirectionByteIsBoundIntoTheNonce() throws {
        let key = testKey(firstBytes: [9, 9, 9])
        let token: UInt32 = 0xAABB_CCDD

        let box = try SessionCrypto.seal(heartbeatInner, key: key, direction: .up, counter: 1, token: token)
        XCTAssertEqual(box.count, heartbeatInner.count + 16)
        // Regression pin: seal/open must hand back zero-based Data, never a
        // slice with a leaked startIndex (CryptoKit's ciphertext/tag are
        // slices of its combined buffer).
        XCTAssertEqual(box.startIndex, 0)

        let plain = try SessionCrypto.open(box, key: key, direction: .up, counter: 1, token: token)
        XCTAssertEqual(plain, heartbeatInner)
        XCTAssertEqual(plain.startIndex, 0)

        // Direction / counter / token mismatch each fail authentication.
        XCTAssertThrowsError(try SessionCrypto.open(box, key: key, direction: .down, counter: 1, token: token))
        XCTAssertThrowsError(try SessionCrypto.open(box, key: key, direction: .up, counter: 2, token: token))
        XCTAssertThrowsError(try SessionCrypto.open(box, key: key, direction: .up, counter: 1, token: 0xAABB_CCDE))

        // Same key + counter, opposite direction → different ciphertext
        // (no nonce reuse across directions).
        let boxDown = try SessionCrypto.seal(heartbeatInner, key: key, direction: .down, counter: 1, token: token)
        XCTAssertEqual(boxDown.count, box.count)
        XCTAssertNotEqual(boxDown, box)
    }

    func testOpenRejectsTamperedAndTruncatedBoxes() throws {
        let key = testKey(firstBytes: [9, 9, 9])
        let box = try SessionCrypto.seal(heartbeatInner, key: key, direction: .up, counter: 1, token: 1)

        // One flipped ciphertext byte fails the Poly1305 tag.
        var tampered = box
        tampered[0] ^= 0x01
        XCTAssertThrowsError(try SessionCrypto.open(tampered, key: key, direction: .up, counter: 1, token: 1))

        // Shorter than a tag cannot even be attempted.
        XCTAssertThrowsError(
            try SessionCrypto.open(Data([0x01, 0x02, 0x03]), key: key, direction: .up, counter: 1, token: 1)
        ) { error in
            XCTAssertEqual(error as? SessionCryptoError, .malformedBox)
        }
    }

    func testTheClientToServerSendFramingDecryptsAsTheSatelliteExpects() throws {
        // Reconstruct one packet the way the data plane builds it: the FIRST
        // send uses counter 1 (NOT 0 — the pre-protocol-1 off-by-one), nonce
        // direction client→server, AAD = token(4 BE). The satellite decrypts
        // the opposite way; here we prove the bytes round-trip under those
        // exact parameters.
        let sessionKey = testKey(firstBytes: [0xAB]) // arbitrary derived key
        let token: UInt32 = 0x0007_A1B2

        let box = try SessionCrypto.seal(heartbeatInner, key: sessionKey, direction: .up, counter: 1, token: token)

        // The satellite decrypts with the client→server direction + the SAME
        // counter 1 + token AAD.
        let plain = try SessionCrypto.open(box, key: sessionKey, direction: .up, counter: 1, token: token)
        XCTAssertEqual(plain, heartbeatInner)

        // Off-by-one (counter 0) and a missing direction byte both fail auth.
        XCTAssertThrowsError(try SessionCrypto.open(box, key: sessionKey, direction: .up, counter: 0, token: token))
        XCTAssertThrowsError(try SessionCrypto.open(box, key: sessionKey, direction: .down, counter: 1, token: token))
    }

    // MARK: - constantTimeEquals

    func testConstantTimeEqualsComparesContentNotIdentity() {
        XCTAssertTrue(SessionCrypto.constantTimeEquals(Data([1, 2, 3]), Data([1, 2, 3])))
        XCTAssertFalse(SessionCrypto.constantTimeEquals(Data([1, 2, 3]), Data([1, 2, 4])))
        XCTAssertFalse(SessionCrypto.constantTimeEquals(Data([1, 2, 3]), Data([1, 2])))
        XCTAssertTrue(SessionCrypto.constantTimeEquals(Data(), Data()))
    }
}
