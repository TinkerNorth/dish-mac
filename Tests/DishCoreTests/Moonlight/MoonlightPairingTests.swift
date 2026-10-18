// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Security
import XCTest
@testable import DishCore

/// The five phases against a reference host built from the same primitives,
/// the way Wolf's server does them: both ends authenticate, a wrong PIN is
/// caught on the client side, and every short or forged answer is refused.
/// The RSA keys are minted in memory per run; nothing is committed.
final class MoonlightPairingTests: XCTestCase {

    private var client: RsaIdentity!
    private var server: RsaIdentity!

    override func setUpWithError() throws {
        try super.setUpWithError()
        client = try RsaIdentity(certificateSignature: Data((0 ..< 256).map { UInt8($0 & 0xFF) }))
        server = try RsaIdentity(certificateSignature: Data((0 ..< 256).map { UInt8(255 - $0 & 0xFF) }))
    }

    private let salt = Data((1 ... 16).map { UInt8($0) })
    private let challenge = Data((0 ..< 16).map { UInt8(0x40 + $0) })
    private let secret = Data((0 ..< 16).map { UInt8(0x80 + $0) })

    private func pairing(pin: String) -> MoonlightPairing {
        var queue = [salt, challenge, secret]
        return MoonlightPairing(identity: client, pin: pin) { length in
            let next = queue.removeFirst()
            XCTAssertEqual(next.count, length)
            return next
        }
    }

    func testTheFullRoundTripAuthenticatesBothEnds() throws {
        let host = ReferenceHost(pin: "0451", identity: server, client: client)
        var pairing = pairing(pin: "0451")
        let phase1 = pairing.phase1Params(uniqueId: "dish-uid")
        XCTAssertEqual(value("salt", in: phase1), hexString(salt))
        XCTAssertTrue(pairing.onPhase1(serverCertificatePem: host.serverCertificate(saltHex: value("salt", in: phase1))))
        let phase2 = try XCTUnwrap(pairing.phase2Params(uniqueId: "dish-uid"))
        XCTAssertTrue(try pairing.onPhase2(challengeResponseHex: XCTUnwrap(host.challengeResponse(clientChallengeHex: value(
            "clientchallenge",
            in: phase2
        )))))
        let phase3 = try XCTUnwrap(pairing.phase3Params(uniqueId: "dish-uid"))
        let pairingSecret = try XCTUnwrap(host.clientHashResponse(serverChallengeRespHex: value("serverchallengeresp", in: phase3)))
        XCTAssertTrue(pairing.onPhase3(pairingSecretHex: pairingSecret, verifier: server), "the client authenticates the host")
        let phase4 = try XCTUnwrap(pairing.phase4Params(uniqueId: "dish-uid"))
        XCTAssertTrue(
            host.verifyClient(clientPairingSecretHex: value("clientpairingsecret", in: phase4)),
            "the host authenticates the client"
        )
        XCTAssertEqual(MoonlightPairing.phase5Params(uniqueId: "dish-uid").last?.1, "pairchallenge")
    }

    func testAWrongPinIsCaughtByTheClientAtPhaseThree() throws {
        let host = ReferenceHost(pin: "1234", identity: server, client: client)
        var pairing = pairing(pin: "0451")
        XCTAssertTrue(pairing.onPhase1(serverCertificatePem: host.serverCertificate(saltHex: hexString(salt))))
        let phase2 = try XCTUnwrap(pairing.phase2Params(uniqueId: "u"))
        let response = try XCTUnwrap(host.challengeResponse(clientChallengeHex: value("clientchallenge", in: phase2)))
        XCTAssertTrue(pairing.onPhase2(challengeResponseHex: response), "the shape is right, the contents are not")
        let phase3 = try XCTUnwrap(pairing.phase3Params(uniqueId: "u"))
        let pairingSecret = try XCTUnwrap(host.clientHashResponse(serverChallengeRespHex: value("serverchallengeresp", in: phase3)))
        XCTAssertFalse(pairing.onPhase3(pairingSecretHex: pairingSecret, verifier: server), "the hash the host committed to does not match")
    }

    func testEveryPhaseNamesTheDeviceTheUpdateStateAndTheClient() throws {
        var pairing = pairing(pin: "0451")
        let phase1 = pairing.phase1Params(uniqueId: "dish-uid")
        XCTAssertEqual(phase1.map(\.0), ["devicename", "updateState", "uniqueid", "phrase", "salt", "clientcert"])
        XCTAssertEqual(value("devicename", in: phase1), "roth")
        XCTAssertEqual(value("updateState", in: phase1), "1")
        XCTAssertEqual(value("phrase", in: phase1), "getservercert")
        XCTAssertEqual(value("clientcert", in: phase1), hexString(Data(client.certificatePem.utf8)), "the PEM text itself, as hex")
        let host = ReferenceHost(pin: "0451", identity: server, client: client)
        XCTAssertTrue(pairing.onPhase1(serverCertificatePem: host.serverCertificate(saltHex: hexString(salt))))
        for params in [pairing.phase2Params(uniqueId: "u"), pairing.phase3Params(uniqueId: "u"), pairing.phase4Params(uniqueId: "u")] {
            XCTAssertEqual(try XCTUnwrap(params).prefix(3).map(\.0), ["devicename", "updateState", "uniqueid"])
        }
        XCTAssertEqual(MoonlightPairing.phase5Params(uniqueId: "u").map(\.0), ["devicename", "updateState", "uniqueid", "phrase"])
    }

    func testAnswersThatAreNotWhatTheProtocolSaysAreRefused() throws {
        var pairing = pairing(pin: "0451")
        XCTAssertFalse(pairing.onPhase1(serverCertificatePem: "not a certificate"))
        let host = ReferenceHost(pin: "0451", identity: server, client: client)
        XCTAssertTrue(pairing.onPhase1(serverCertificatePem: host.serverCertificate(saltHex: hexString(salt))))
        XCTAssertFalse(pairing.onPhase2(challengeResponseHex: "zz"), "not hex")
        XCTAssertFalse(pairing.onPhase2(challengeResponseHex: hexString(Data(count: 32))), "too short to hold the hash and the challenge")
        let phase2 = try XCTUnwrap(pairing.phase2Params(uniqueId: "u"))
        XCTAssertTrue(try pairing.onPhase2(challengeResponseHex: XCTUnwrap(host.challengeResponse(clientChallengeHex: value(
            "clientchallenge",
            in: phase2
        )))))
        let phase3 = try XCTUnwrap(pairing.phase3Params(uniqueId: "u"))
        let pairingSecret = try XCTUnwrap(host.clientHashResponse(serverChallengeRespHex: value("serverchallengeresp", in: phase3)))
        XCTAssertFalse(
            pairing.onPhase3(pairingSecretHex: hexString(Data(count: 16 + 63)), verifier: server),
            "too short to carry a signature"
        )
        var forged = hexData(pairingSecret)
        forged[forged.count - 1] ^= 0x01
        XCTAssertFalse(pairing.onPhase3(pairingSecretHex: hexString(forged), verifier: server), "a host that cannot sign its own secret")
        var otherSecret = hexData(pairingSecret)
        otherSecret[0] ^= 0x01
        XCTAssertFalse(
            pairing.onPhase3(pairingSecretHex: hexString(otherSecret), verifier: server),
            "a secret that does not match the hash"
        )
        XCTAssertTrue(pairing.onPhase3(pairingSecretHex: pairingSecret, verifier: server), "the genuine one still passes")
    }

    private func value(_ name: String, in params: [(String, String)]) -> String {
        params.first { $0.0 == name }?.1 ?? ""
    }
}

/// An RSA-2048 key minted in memory, a synthetic certificate around a chosen
/// signature, and the two protocol roles it can play.
private final class RsaIdentity: MoonlightClientIdentity, MoonlightSignatureVerifier {
    let privateKey: SecKey
    let certificateSignature: Data
    let certificatePem: String

    init(certificateSignature: Data) throws {
        var error: Unmanaged<CFError>?
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048]
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw XCTSkip("no RSA key: \(String(describing: error))")
        }
        privateKey = key
        self.certificateSignature = certificateSignature
        let bitString = Data([0x03, 0x82, 0x01, 0x01, 0x00]) + certificateSignature
        let body = Data([0x30, 0x02, 0x05, 0x00]) + Data([0x30, 0x03, 0x06, 0x01, 0x2A]) + bitString
        certificatePem = MoonlightCertificate.pem(fromDer: Data([0x30, 0x82, UInt8(body.count >> 8), UInt8(body.count & 0xFF)]) + body)
    }

    func sign(_ data: Data) -> Data? {
        var error: Unmanaged<CFError>?
        return SecKeyCreateSignature(privateKey, .rsaSignatureMessagePKCS1v15SHA256, data as CFData, &error) as Data?
    }

    func verify(certificatePem: String, data: Data, signature: Data) -> Bool {
        guard let publicKey = SecKeyCopyPublicKey(privateKey) else { return false }
        var error: Unmanaged<CFError>?
        return SecKeyVerifySignature(publicKey, .rsaSignatureMessagePKCS1v15SHA256, data as CFData, signature as CFData, &error)
    }
}

/// The host half of the five phases, from the same primitives: every value
/// is one a live host would have had to produce, so a client that skips a
/// check fails here.
private final class ReferenceHost {
    private let pin: String
    private let identity: RsaIdentity
    private let client: RsaIdentity
    private var aesKey = Data()
    private let serverSecret = Data((0 ..< 16).map { UInt8(0x10 + $0) })
    private let serverChallenge = Data((0 ..< 16).map { UInt8(0x20 + $0) })
    private var storedClientHash = Data()
    private var clientChallenge = Data()

    init(pin: String, identity: RsaIdentity, client: RsaIdentity) {
        self.pin = pin
        self.identity = identity
        self.client = client
    }

    func serverCertificate(saltHex: String) -> String {
        aesKey = MoonlightPairingCrypto.pairingKey(salt: hexData(saltHex), pin: pin)
        return identity.certificatePem
    }

    func challengeResponse(clientChallengeHex: String) -> String? {
        guard let challenge = MoonlightPairingCrypto.aesEcbDecrypt(key: aesKey, data: hexData(clientChallengeHex)) else { return nil }
        clientChallenge = challenge
        let hash = MoonlightPairingCrypto.sha256(clientChallenge, identity.certificateSignature, serverSecret)
        return MoonlightPairingCrypto.aesEcbEncrypt(key: aesKey, data: hash + serverChallenge).map(hexString)
    }

    func clientHashResponse(serverChallengeRespHex: String) -> String? {
        guard let hash = MoonlightPairingCrypto.aesEcbDecrypt(key: aesKey, data: hexData(serverChallengeRespHex)) else { return nil }
        storedClientHash = hash
        return identity.sign(serverSecret).map { hexString(serverSecret + $0) }
    }

    func verifyClient(clientPairingSecretHex: String) -> Bool {
        let secret = hexData(clientPairingSecretHex)
        let clientSecret = secret.prefix(16)
        let signature = secret.dropFirst(16)
        let expected = MoonlightPairingCrypto.sha256(serverChallenge, client.certificateSignature, clientSecret)
        guard MoonlightPairingCrypto.constantTimeEquals(expected, storedClientHash) else { return false }
        return client.verify(certificatePem: "", data: clientSecret, signature: signature)
    }
}
