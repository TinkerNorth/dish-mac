// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// The client side of the Moonlight PIN pairing (Wolf http-pairing.adoc and
// its host in moonlight.cpp). Five phases derive a shared trust: the dish
// shows a PIN, the user types it into the host, and a challenge and response
// over AES-ECB plus RSA signatures authenticate both ends. This type owns
// the crypto and the phase order only; the engine drives the HTTP and parses
// the XML. Randomness is injected so a test is byte-deterministic.

import Foundation

/// The dish's persistent Moonlight identity: a self-signed X.509 certificate
/// and the RSA key behind it, generated once and used for every host. The
/// engine owns the key; the pairing hashes the certificate's signature bytes
/// and asks for one signature.
public protocol MoonlightClientIdentity {
    var certificatePem: String { get }
    /// The certificate's X.509 signatureValue bytes.
    var certificateSignature: Data { get }
    /// RSA-SHA256, PKCS#1 v1.5, over `data`; nil when the key cannot sign.
    func sign(_ data: Data) -> Data?
}

/// Verifies the host's RSA-SHA256 signature with the public key inside the
/// certificate it sent in phase 1.
public protocol MoonlightSignatureVerifier {
    func verify(certificatePem: String, data: Data, signature: Data) -> Bool
}

public struct MoonlightPairing {
    public static let saltLength = 16
    public static let hashLength = 32
    /// A 2048-bit RSA signature is 256 bytes; any reasonable length pairs,
    /// so a host with a differently sized key still can.
    public static let minimumSignatureLength = 64
    /// What every real client sends on every phase; hosts ignore both.
    public static let deviceName = "roth"

    public let salt: Data
    private let identity: MoonlightClientIdentity
    private let aesKey: Data
    private let clientChallenge: Data
    private let clientSecret: Data
    private var serverCertificatePem = ""
    private var serverCertificateSignature = Data()
    private var serverResponseHash = Data()
    private var serverChallenge = Data()

    public init(identity: MoonlightClientIdentity, pin: String, random: (Int) -> Data) {
        self.identity = identity
        salt = random(Self.saltLength)
        aesKey = MoonlightPairingCrypto.pairingKey(salt: salt, pin: pin)
        clientChallenge = random(MoonlightPairingCrypto.blockLength)
        clientSecret = random(MoonlightPairingCrypto.blockLength)
    }

    /// Phase 1, plain HTTP: the salt and the client certificate.
    public func phase1Params(uniqueId: String) -> [(String, String)] {
        Self.common(uniqueId) + [
            ("phrase", "getservercert"),
            ("salt", hexEncodeLower(salt)),
            ("clientcert", hexEncodeLower(Data(identity.certificatePem.utf8)))
        ]
    }

    /// The host's `plaincert`; false when it is not a certificate.
    public mutating func onPhase1(serverCertificatePem: String) -> Bool {
        guard let der = MoonlightCertificate.der(fromPem: serverCertificatePem),
              let signature = MoonlightCertificate.signatureBytes(der: der) else { return false }
        self.serverCertificatePem = serverCertificatePem
        serverCertificateSignature = signature
        return true
    }

    /// Phase 2: the client challenge, encrypted.
    public func phase2Params(uniqueId: String) -> [(String, String)]? {
        MoonlightPairingCrypto.aesEcbEncrypt(key: aesKey, data: clientChallenge).map {
            Self.common(uniqueId) + [("clientchallenge", hexEncodeLower($0))]
        }
    }

    /// The host's `challengeresponse`: `serverHash(32) || serverChallenge(16)`
    /// once decrypted; the hash is checked when phase 3 reveals the secret.
    public mutating func onPhase2(challengeResponseHex: String) -> Bool {
        guard let encrypted = hexDecode(challengeResponseHex),
              let decrypted = MoonlightPairingCrypto.aesEcbDecrypt(key: aesKey, data: encrypted),
              decrypted.count >= Self.hashLength + MoonlightPairingCrypto.blockLength else { return false }
        serverResponseHash = decrypted.prefix(Self.hashLength)
        serverChallenge = decrypted.dropFirst(Self.hashLength).prefix(MoonlightPairingCrypto.blockLength)
        return true
    }

    /// Phase 3: `ECB(SHA-256(serverChallenge || clientCertSig || clientSecret))`,
    /// the hash the host holds against phase 4.
    public func phase3Params(uniqueId: String) -> [(String, String)]? {
        let clientHash = MoonlightPairingCrypto.sha256(serverChallenge, identity.certificateSignature, clientSecret)
        return MoonlightPairingCrypto.aesEcbEncrypt(key: aesKey, data: clientHash).map {
            Self.common(uniqueId) + [("serverchallengeresp", hexEncodeLower($0))]
        }
    }

    /// The host's `pairingsecret`: `serverSecret(16) || signature`. The host
    /// is authentic when its phase-2 hash equals
    /// `SHA-256(clientChallenge || serverCertSig || serverSecret)` and the
    /// secret carries its certificate's signature.
    public mutating func onPhase3(pairingSecretHex: String, verifier: MoonlightSignatureVerifier) -> Bool {
        guard let secret = hexDecode(pairingSecretHex),
              secret.count >= MoonlightPairingCrypto.blockLength + Self.minimumSignatureLength else { return false }
        let serverSecret = secret.prefix(MoonlightPairingCrypto.blockLength)
        let serverSignature = secret.dropFirst(MoonlightPairingCrypto.blockLength)
        let expected = MoonlightPairingCrypto.sha256(clientChallenge, serverCertificateSignature, serverSecret)
        guard MoonlightPairingCrypto.constantTimeEquals(expected, serverResponseHash) else { return false }
        return verifier.verify(certificatePem: serverCertificatePem, data: serverSecret, signature: serverSignature)
    }

    /// Phase 4: `clientSecret(16) || RSA-SHA256(clientSecret)`.
    public func phase4Params(uniqueId: String) -> [(String, String)]? {
        identity.sign(clientSecret).map {
            Self.common(uniqueId) + [("clientpairingsecret", hexEncodeLower(clientSecret + $0))]
        }
    }

    /// Phase 5, over the mutual TLS the pairing just made possible.
    public static func phase5Params(uniqueId: String) -> [(String, String)] {
        common(uniqueId) + [("phrase", "pairchallenge")]
    }

    private static func common(_ uniqueId: String) -> [(String, String)] {
        [("devicename", deviceName), ("updateState", "1"), ("uniqueid", uniqueId)]
    }
}
