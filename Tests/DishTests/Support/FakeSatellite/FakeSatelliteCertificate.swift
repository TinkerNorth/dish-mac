// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// Runtime-minted self-signed P256 TLS identities for FakeSatellite.
//
// Every harness instance mints a FRESH key pair + certificate at runtime (a
// small ASN.1 DER writer + SecKeyCreateSignature), so no key material is ever
// committed to the repo and two instances always present different
// certificates — exactly what the TOFU imposter tests need. The DER (and its
// SHA-256 fingerprint) is available fully headlessly. Serving TLS
// additionally requires a `SecIdentity`, which macOS only assembles when the
// private key lives in a keychain, so the key is generated directly inside a
// throwaway file keychain under the temporary directory (legacy SecKeychain
// API — deprecated since macOS 12 but the only prompt-free, entitlement-free
// keychain an unsigned `swift test` runner can create headlessly; a key
// merely SecItemAdd-ed by ref is NOT matched by SecIdentityCreateWithCertificate,
// the key must be born in the keychain). If any step fails, the mint falls
// back to an ephemeral key: `secIdentity()` returns nil, the harness serves
// plain HTTP, and TOFU tests still exercise fingerprints via `certificateDER`.

import CryptoKit
import Foundation
import Security

/// One instance's certificate + private key, with a lazy best-effort identity.
final class FakeSatelliteIdentity {
    let commonName: String
    let certificateDER: Data
    let certificate: SecCertificate
    let privateKey: SecKey
    /// Set when `privateKey` was generated inside the throwaway keychain
    /// (the precondition for assembling a `SecIdentity`).
    private let keychain: SecKeychain?

    private let lock = NSLock()
    private var cachedIdentity: SecIdentity?
    private var identityResolved = false

    init(
        commonName: String,
        certificateDER: Data,
        certificate: SecCertificate,
        privateKey: SecKey,
        keychain: SecKeychain?
    ) {
        self.commonName = commonName
        self.certificateDER = certificateDER
        self.certificate = certificate
        self.privateKey = privateKey
        self.keychain = keychain
    }

    /// SHA-256 of the DER — the TOFU pin the client side computes.
    var fingerprintSHA256Hex: String {
        FakeSatelliteCrypto.hexString(Data(SHA256.hash(data: certificateDER)))
    }

    /// Best-effort `SecIdentity` for NWListener TLS; nil when the throwaway
    /// keychain route is unavailable (the harness then falls back to HTTP).
    func secIdentity() -> SecIdentity? {
        lock.lock()
        defer { lock.unlock() }
        if identityResolved { return cachedIdentity }
        identityResolved = true
        guard let keychain else { return nil }
        let certAdd: [CFString: Any] = [
            kSecUseKeychain: keychain,
            kSecValueRef: certificate,
            kSecAttrLabel: "FakeSatellite cert \(commonName)"
        ]
        let certStatus = SecItemAdd(certAdd as CFDictionary, nil)
        guard certStatus == errSecSuccess || certStatus == errSecDuplicateItem else { return nil }
        var identity: SecIdentity?
        guard SecIdentityCreateWithCertificate(keychain, certificate, &identity) == errSecSuccess else { return nil }
        cachedIdentity = identity
        return cachedIdentity
    }
}

enum FakeSatelliteCertificateError: Error {
    case keyGenerationFailed(String)
    case signingFailed(String)
    case certificateRejected
}

enum FakeSatelliteCertificateMint {

    /// Mints a fresh self-signed P256 certificate (ecdsa-with-SHA256,
    /// SAN = localhost + 127.0.0.1, valid ~2 years around now). The key pair
    /// is generated inside the throwaway keychain when possible (TLS-capable
    /// identity), else ephemerally (DER-only identity, HTTP fallback).
    static func mint(commonName: String) throws -> FakeSatelliteIdentity {
        if let keychain = FakeSatelliteThrowawayKeychain.shared,
           let keychainKey = keychainBackedKey(keychain: keychain, label: commonName)
        {
            return try mintCertificate(commonName: commonName, privateKey: keychainKey, keychain: keychain)
        }
        var error: Unmanaged<CFError>?
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits: 256
        ]
        guard let ephemeralKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw FakeSatelliteCertificateError.keyGenerationFailed(describe(error))
        }
        return try mintCertificate(commonName: commonName, privateKey: ephemeralKey, keychain: nil)
    }

    /// Builds + self-signs the certificate for an existing P256 private key.
    static func mintCertificate(commonName: String, privateKey: SecKey, keychain: SecKeychain?) throws -> FakeSatelliteIdentity {
        var error: Unmanaged<CFError>?
        guard let publicKey = SecKeyCopyPublicKey(privateKey),
              let publicPoint = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else
        {
            throw FakeSatelliteCertificateError.keyGenerationFailed(describe(error))
        }
        let tbs = tbsCertificate(commonName: commonName, publicKeyX963: publicPoint)
        guard let signature = SecKeyCreateSignature(privateKey, .ecdsaSignatureMessageX962SHA256, tbs as CFData, &error) as Data? else {
            throw FakeSatelliteCertificateError.signingFailed(describe(error))
        }
        let der = Asn1.sequence(tbs + signatureAlgorithm + Asn1.bitString(signature))
        guard let certificate = SecCertificateCreateWithData(nil, der as CFData) else {
            throw FakeSatelliteCertificateError.certificateRejected
        }
        return FakeSatelliteIdentity(
            commonName: commonName,
            certificateDER: der,
            certificate: certificate,
            privateKey: privateKey,
            keychain: keychain
        )
    }

    /// P256 key generated directly inside the throwaway keychain — the only
    /// arrangement `SecIdentityCreateWithCertificate` can later match.
    private static func keychainBackedKey(keychain: SecKeychain, label: String) -> SecKey? {
        var error: Unmanaged<CFError>?
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits: 256,
            kSecUseKeychain: keychain,
            kSecAttrIsPermanent: true,
            kSecAttrLabel: "FakeSatellite key \(label)"
        ]
        return SecKeyCreateRandomKey(attributes as CFDictionary, &error)
    }

    private static func describe(_ error: Unmanaged<CFError>?) -> String {
        error.map { String(describing: $0.takeRetainedValue()) } ?? "unknown Security error"
    }

    // MARK: - X.509 assembly

    private static let oidEcPublicKey: [UInt8] = [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01]
    private static let oidPrime256v1: [UInt8] = [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07]
    private static let oidEcdsaWithSha256: [UInt8] = [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x02]
    private static let oidCommonName: [UInt8] = [0x55, 0x04, 0x03]
    private static let oidSubjectAltName: [UInt8] = [0x55, 0x1D, 0x11]

    /// AlgorithmIdentifier for ecdsa-with-SHA256 (parameters absent per RFC 5758).
    private static var signatureAlgorithm: Data {
        Asn1.sequence(Asn1.oid(oidEcdsaWithSha256))
    }

    private static func tbsCertificate(commonName: String, publicKeyX963: Data) -> Data {
        var serial = Data((0 ..< 8).map { _ in UInt8.random(in: 0 ... 255) })
        serial[serial.startIndex] &= 0x7F // keep the INTEGER positive
        let name = Asn1.sequence(Asn1.set(Asn1.sequence(Asn1.oid(oidCommonName) + Asn1.utf8String(commonName))))
        let spki = Asn1.sequence(
            Asn1.sequence(Asn1.oid(oidEcPublicKey) + Asn1.oid(oidPrime256v1))
                + Asn1.bitString(publicKeyX963)
        )
        let altNames = Asn1.sequence(
            Asn1.tagged(0x82, Data("localhost".utf8)) // dNSName [2]
                + Asn1.tagged(0x87, Data([127, 0, 0, 1])) // iPAddress [7]
        )
        let extensions = Asn1.explicitTag(
            3,
            Asn1.sequence(Asn1.sequence(Asn1.oid(oidSubjectAltName) + Asn1.octetString(altNames)))
        )
        return Asn1.sequence(
            Asn1.explicitTag(0, Asn1.integer(2)) // version v3
                + Asn1.integer(serial)
                + signatureAlgorithm
                + name // issuer == subject: self-signed
                + validity()
                + name
                + spki
                + extensions
        )
    }

    private static func validity() -> Data {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        formatter.dateFormat = "yyMMddHHmmss'Z'"
        let now = Date()
        let notBefore = formatter.string(from: now.addingTimeInterval(-3600))
        let notAfter = formatter.string(from: now.addingTimeInterval(2 * 365 * 24 * 3600))
        return Asn1.sequence(Asn1.utcTime(notBefore) + Asn1.utcTime(notAfter))
    }
}

/// Minimal DER writer — exactly the shapes an X.509 v3 certificate needs.
private enum Asn1 {

    static func lengthField(_ count: Int) -> Data {
        if count < 0x80 { return Data([UInt8(count)]) }
        var bytes: [UInt8] = []
        var value = count
        while value > 0 {
            bytes.insert(UInt8(value & 0xFF), at: 0)
            value >>= 8
        }
        return Data([0x80 | UInt8(bytes.count)] + bytes)
    }

    static func tagged(_ tag: UInt8, _ content: Data) -> Data {
        Data([tag]) + lengthField(content.count) + content
    }

    static func sequence(_ content: Data) -> Data {
        tagged(0x30, content)
    }

    static func set(_ content: Data) -> Data {
        tagged(0x31, content)
    }

    static func octetString(_ content: Data) -> Data {
        tagged(0x04, content)
    }

    static func utf8String(_ value: String) -> Data {
        tagged(0x0C, Data(value.utf8))
    }

    static func utcTime(_ value: String) -> Data {
        tagged(0x17, Data(value.utf8))
    }

    static func oid(_ body: [UInt8]) -> Data {
        tagged(0x06, Data(body))
    }

    /// BIT STRING with zero unused bits.
    static func bitString(_ content: Data) -> Data {
        tagged(0x03, Data([0x00]) + content)
    }

    /// Context-specific constructed [n] EXPLICIT wrapper.
    static func explicitTag(_ number: UInt8, _ content: Data) -> Data {
        tagged(0xA0 | number, content)
    }

    /// Small non-negative INTEGER (used for the X.509 version field).
    static func integer(_ value: UInt8) -> Data {
        tagged(0x02, Data([value]))
    }

    /// Arbitrary-width positive INTEGER from raw big-endian bytes.
    static func integer(_ raw: Data) -> Data {
        var body = raw
        while body.count > 1, body[body.startIndex] == 0, body[body.startIndex + 1] & 0x80 == 0 {
            body = body.dropFirst()
        }
        if let first = body.first, first & 0x80 != 0 {
            body = Data([0x00]) + body
        }
        return tagged(0x02, body)
    }
}

/// One throwaway legacy file keychain per test process, shared by every
/// FakeSatellite identity minted in that process. The legacy SecKeychain call
/// is deprecated but is the only keychain an unsigned, unentitled test runner
/// can create headlessly without prompts; the file sits in the per-boot
/// temporary directory and is discarded with it.
enum FakeSatelliteThrowawayKeychain {

    static var shared: SecKeychain? {
        lock.lock()
        defer { lock.unlock() }
        if resolved { return keychain }
        resolved = true
        keychain = create()
        return keychain
    }

    private static let lock = NSLock()
    private static var resolved = false
    private static var keychain: SecKeychain?

    private static func create() -> SecKeychain? {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fake-satellite-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("throwaway.keychain").path
        // Throwaway unlock phrase for a throwaway file — deliberately not a secret.
        let phrase = "fake-satellite-throwaway"
        var created: SecKeychain?
        let status = phrase.withCString { phraseBytes in
            SecKeychainCreate(path, UInt32(phrase.utf8.count), phraseBytes, false, nil, &created)
        }
        guard status == errSecSuccess else { return nil }
        return created
    }
}
