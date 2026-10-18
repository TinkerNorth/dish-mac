// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// The primitives of the Moonlight PIN pairing (Wolf http-pairing.adoc): the
// key the PIN derives, the AES-128-ECB blocks the challenges travel in, and
// the hashes both ends commit to. ECB, which no data would be trusted to, is
// here because the protocol prescribes it for exact 16-byte multiples; a
// client that used any other mode could not pair. CommonCrypto supplies the
// one primitive CryptoKit lacks.

import CommonCrypto
import CryptoKit
import Foundation

public enum MoonlightPairingCrypto {
    public static let aesKeyLength = 16
    public static let blockLength = 16

    public static func sha256(_ parts: Data...) -> Data {
        var hasher = SHA256()
        for part in parts {
            hasher.update(data: part)
        }
        return Data(hasher.finalize())
    }

    /// `SHA-256(salt || PIN)[:16]`: the salt is the client's sixteen random
    /// bytes from phase 1, the PIN the four ASCII digits the user types.
    public static func pairingKey(salt: Data, pin: String) -> Data {
        sha256(salt, Data(pin.utf8)).prefix(aesKeyLength)
    }

    /// Nil for a key that is not 16 bytes or data that is not a whole number
    /// of blocks: the protocol's blobs always are, so nil is a wire fault.
    public static func aesEcbEncrypt(key: Data, data: Data) -> Data? {
        ecb(kCCEncrypt, key: key, data: data)
    }

    public static func aesEcbDecrypt(key: Data, data: Data) -> Data? {
        ecb(kCCDecrypt, key: key, data: data)
    }

    /// Equal without a timing side channel, for the hashes the pairing checks.
    public static func constantTimeEquals(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for (left, right) in zip(lhs, rhs) {
            difference |= left ^ right
        }
        return difference == 0
    }

    private static func ecb(_ operation: Int, key: Data, data: Data) -> Data? {
        guard key.count == aesKeyLength, !data.isEmpty, data.count % blockLength == 0 else { return nil }
        var out = [UInt8](repeating: 0, count: data.count)
        var moved = 0
        let status = key.withUnsafeBytes { keyBytes in
            data.withUnsafeBytes { dataBytes in
                CCCrypt(
                    CCOperation(operation),
                    CCAlgorithm(kCCAlgorithmAES),
                    CCOptions(kCCOptionECBMode),
                    keyBytes.baseAddress,
                    key.count,
                    nil,
                    dataBytes.baseAddress,
                    data.count,
                    &out,
                    out.count,
                    &moved
                )
            }
        }
        guard Int(status) == kCCSuccess, moved == data.count else { return nil }
        return Data(out)
    }
}
