// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// The dish's persistent Moonlight identity: one RSA-2048 key, born in the
// keychain so macOS can assemble the SecIdentity that mutual TLS presents,
// and the self-signed certificate around it, generated once and used for
// every host. The pairing signs with the key and hashes the certificate's
// signature bytes; every HTTPS call afterwards authenticates with the same
// key, which is how a host knows a paired client.

import DishCore
import Foundation
import Security

final class MoonlightIdentityStore: MoonlightClientIdentity, MoonlightSignatureVerifier {
    static let keyTag = Data("com.tinkernorth.dish.moonlight-identity".utf8)
    static let keyLabel = "Dish Moonlight client key"
    static let certificateLabel = "Dish Moonlight client certificate"
    static let keyBits = 2048

    let privateKey: SecKey
    let certificateDER: Data
    let certificate: SecCertificate
    private let keychain: SecKeychain?
    private let lock = NSLock()
    private var resolvedIdentity: SecIdentity?
    private var identityResolved = false

    init(privateKey: SecKey, certificateDER: Data, certificate: SecCertificate, keychain: SecKeychain?) {
        self.privateKey = privateKey
        self.certificateDER = certificateDER
        self.certificate = certificate
        self.keychain = keychain
    }

    var certificatePem: String {
        MoonlightCertificate.pem(fromDer: certificateDER)
    }

    var certificateSignature: Data {
        MoonlightCertificate.signatureBytes(der: certificateDER) ?? Data()
    }

    var fingerprintHex: String {
        MoonlightCertificate.fingerprintHex(der: certificateDER)
    }

    func sign(_ data: Data) -> Data? {
        SecKeyCreateSignature(privateKey, .rsaSignatureMessagePKCS1v15SHA256, data as CFData, nil) as Data?
    }

    /// The host's RSA-SHA256 signature, checked with the key inside the certificate it sent.
    func verify(certificatePem: String, data: Data, signature: Data) -> Bool {
        guard let der = MoonlightCertificate.der(fromPem: certificatePem),
              let certificate = SecCertificateCreateWithData(nil, der as CFData),
              let publicKey = SecCertificateCopyKey(certificate) else { return false }
        return SecKeyVerifySignature(publicKey, .rsaSignatureMessagePKCS1v15SHA256, data as CFData, signature as CFData, nil)
    }

    /// The identity mutual TLS presents; nil when the key did not come from a keychain.
    func secIdentity() -> SecIdentity? {
        lock.lock()
        defer { lock.unlock() }
        if identityResolved { return resolvedIdentity }
        identityResolved = true
        var identity: SecIdentity?
        guard SecIdentityCreateWithCertificate(keychain, certificate, &identity) == errSecSuccess else { return nil }
        resolvedIdentity = identity
        return identity
    }

    /// The stored identity, or a fresh one minted into the keychain; nil when
    /// the keychain refuses. `keychain` nil means the user's default keychains,
    /// as the app uses; a test passes its own throwaway file keychain.
    static func loadOrCreate(keychain: SecKeychain? = nil) -> MoonlightIdentityStore? {
        if let key = findKey(keychain: keychain), let certificate = findCertificate(keychain: keychain) {
            return MoonlightIdentityStore(
                privateKey: key,
                certificateDER: SecCertificateCopyData(certificate) as Data,
                certificate: certificate,
                keychain: keychain
            )
        }
        guard let key = findKey(keychain: keychain) ?? createKey(keychain: keychain),
              let der = MoonlightCertificateMint.selfSigned(privateKey: key),
              let certificate = SecCertificateCreateWithData(nil, der as CFData) else { return nil }
        var add: [CFString: Any] = [kSecValueRef: certificate, kSecAttrLabel: certificateLabel]
        if let keychain { add[kSecUseKeychain] = keychain }
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecDuplicateItem else { return nil }
        return MoonlightIdentityStore(privateKey: key, certificateDER: der, certificate: certificate, keychain: keychain)
    }

    private static func findKey(keychain: SecKeychain?) -> SecKey? {
        var query: [CFString: Any] = [
            kSecClass: kSecClassKey,
            kSecAttrApplicationTag: keyTag,
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate,
            kSecReturnRef: true
        ]
        if let keychain { query[kSecMatchSearchList] = [keychain] }
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let item,
              CFGetTypeID(item) == SecKeyGetTypeID() else { return nil }
        return unsafeDowncast(item, to: SecKey.self)
    }

    private static func findCertificate(keychain: SecKeychain?) -> SecCertificate? {
        var query: [CFString: Any] = [kSecClass: kSecClassCertificate, kSecAttrLabel: certificateLabel, kSecReturnRef: true]
        if let keychain { query[kSecMatchSearchList] = [keychain] }
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let item,
              CFGetTypeID(item) == SecCertificateGetTypeID() else { return nil }
        return unsafeDowncast(item, to: SecCertificate.self)
    }

    /// The key is born inside the keychain: a key merely added by reference is
    /// not one `SecIdentityCreateWithCertificate` can match.
    private static func createKey(keychain: SecKeychain?) -> SecKey? {
        var attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits: keyBits,
            kSecAttrIsPermanent: true,
            kSecAttrApplicationTag: keyTag,
            kSecAttrLabel: keyLabel
        ]
        if let keychain { attributes[kSecUseKeychain] = keychain }
        return SecKeyCreateRandomKey(attributes as CFDictionary, nil)
    }
}
