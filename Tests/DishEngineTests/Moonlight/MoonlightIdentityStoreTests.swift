// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import Security
import XCTest
@testable import DishEngine

/// The dish's Moonlight identity in a throwaway keychain: minted once, read
/// back the same, a certificate macOS parses, a key that signs and an
/// identity mutual TLS can present.
final class MoonlightIdentityStoreTests: XCTestCase {

    private var keychain: SecKeychain!

    override func setUpWithError() throws {
        try super.setUpWithError()
        guard let shared = FakeSatelliteThrowawayKeychain.shared else { throw XCTSkip("no throwaway keychain on this runner") }
        keychain = shared
    }

    func testMintedOnceAndReadBackTheSame() throws {
        let first = try XCTUnwrap(MoonlightIdentityStore.loadOrCreate(keychain: keychain))
        let second = try XCTUnwrap(MoonlightIdentityStore.loadOrCreate(keychain: keychain))
        XCTAssertEqual(first.certificateDER, second.certificateDER, "the same identity for every host, every launch")
        XCTAssertEqual(first.fingerprintHex, second.fingerprintHex)
        XCTAssertEqual(first.fingerprintHex.count, 64)
    }

    func testTheCertificateIsOneMacOSParsesWithTheReferenceSubject() throws {
        let identity = try XCTUnwrap(MoonlightIdentityStore.loadOrCreate(keychain: keychain))
        let certificate = try XCTUnwrap(SecCertificateCreateWithData(nil, identity.certificateDER as CFData))
        XCTAssertEqual(SecCertificateCopySubjectSummary(certificate) as String?, MoonlightCertificateMint.subjectCommonName)
        XCTAssertEqual(identity.certificateSignature.count, 256, "an RSA-2048 signature")
        XCTAssertEqual(MoonlightCertificate.der(fromPem: identity.certificatePem), identity.certificateDER, "the PEM round-trips")
        XCTAssertTrue(identity.certificatePem.hasPrefix("-----BEGIN CERTIFICATE-----\n"))
        XCTAssertNotNil(SecCertificateCopyKey(certificate), "the public key is readable")
    }

    func testTheKeySignsAndTheVerifierChecksWithTheCertificatesKey() throws {
        let identity = try XCTUnwrap(MoonlightIdentityStore.loadOrCreate(keychain: keychain))
        let secret = Data((0 ..< 16).map { UInt8($0) })
        let signature = try XCTUnwrap(identity.sign(secret))
        XCTAssertEqual(signature.count, 256)
        XCTAssertTrue(identity.verify(certificatePem: identity.certificatePem, data: secret, signature: signature))
        var forged = signature
        forged[0] ^= 0x01
        XCTAssertFalse(identity.verify(certificatePem: identity.certificatePem, data: secret, signature: forged))
        XCTAssertFalse(identity.verify(certificatePem: "not a certificate", data: secret, signature: signature))
    }

    func testAnIdentityMutualTlsCanPresent() throws {
        let identity = try XCTUnwrap(MoonlightIdentityStore.loadOrCreate(keychain: keychain))
        XCTAssertNotNil(identity.secIdentity(), "the key was born in the keychain")
    }
}
