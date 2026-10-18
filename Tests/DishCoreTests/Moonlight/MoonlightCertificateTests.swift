// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import CryptoKit
import XCTest
@testable import DishCore

/// PEM armour, the DER walk to the signature, and the fingerprint the trust
/// pin keeps.
final class MoonlightCertificateTests: XCTestCase {

    func testPemAndDerRoundTripWithSixtyFourColumnLines() {
        let der = Data((0 ..< 100).map { UInt8($0) })
        let pem = MoonlightCertificate.pem(fromDer: der)
        XCTAssertTrue(pem.hasPrefix("-----BEGIN CERTIFICATE-----\n"))
        XCTAssertTrue(pem.hasSuffix("-----END CERTIFICATE-----\n"))
        let lines = pem.split(separator: "\n")
        XCTAssertEqual(lines.count, 5, "armour, two full lines, a remainder, armour")
        XCTAssertEqual(lines[1].count, 64)
        XCTAssertEqual(MoonlightCertificate.der(fromPem: pem), der)
    }

    func testPemParsingTolerantOfLineEndingsAndWhitespace() {
        let der = Data([0x30, 0x03, 0x02, 0x01, 0x05])
        let base64 = der.base64EncodedString()
        XCTAssertEqual(
            MoonlightCertificate.der(fromPem: "-----BEGIN CERTIFICATE-----\r\n  \(base64)  \r\n-----END CERTIFICATE-----\r\n"),
            der
        )
        XCTAssertEqual(MoonlightCertificate.der(fromPem: base64), der, "a bare body is still a body")
        XCTAssertNil(MoonlightCertificate.der(fromPem: "-----BEGIN CERTIFICATE-----\n-----END CERTIFICATE-----\n"))
        XCTAssertNil(MoonlightCertificate.der(fromPem: "not base64 at all!"))
    }

    func testTheSignatureIsTheBitStringAfterTheTwoSequences() {
        let signature = Data((0 ..< 40).map { UInt8(200 + $0 % 50) })
        XCTAssertEqual(MoonlightCertificate.signatureBytes(der: certificate(tbs: Data(count: 10), signature: signature)), signature)
        let long = Data(repeating: 0xAB, count: 300)
        XCTAssertEqual(
            MoonlightCertificate.signatureBytes(der: certificate(tbs: Data(count: 400), signature: long)),
            long,
            "long-form lengths"
        )
    }

    func testAnythingButACertificateShapeIsNil() {
        XCTAssertNil(MoonlightCertificate.signatureBytes(der: Data()))
        XCTAssertNil(MoonlightCertificate.signatureBytes(der: Data([0x02, 0x01, 0x05])), "an integer, not a sequence")
        let whole = certificate(tbs: Data(count: 10), signature: Data(count: 8))
        XCTAssertNil(MoonlightCertificate.signatureBytes(der: whole.prefix(whole.count - 3)), "truncated")
        let noSignature = der(0x30, der(0x30, Data(count: 4)) + der(0x30, Data([0x06, 0x01, 0x2A])))
        XCTAssertNil(MoonlightCertificate.signatureBytes(der: noSignature))
    }

    func testTheFingerprintIsTheSha256OfTheDer() {
        let certificateDer = certificate(tbs: Data(count: 10), signature: Data(count: 8))
        XCTAssertEqual(MoonlightCertificate.fingerprintHex(der: certificateDer), hexString(Data(SHA256.hash(data: certificateDer))))
        XCTAssertEqual(MoonlightCertificate.fingerprintHex(der: Data()), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    /// `SEQUENCE { SEQUENCE tbs, SEQUENCE algorithm, BIT STRING 0x00 || signature }`.
    private func certificate(tbs: Data, signature: Data) -> Data {
        der(0x30, der(0x30, tbs) + der(0x30, Data([0x06, 0x01, 0x2A])) + der(0x03, Data([0x00]) + signature))
    }

    private func der(_ tag: UInt8, _ content: Data) -> Data {
        var out = Data([tag])
        if content.count < 0x80 {
            out.append(UInt8(content.count))
        } else if content.count < 0x100 {
            out.append(contentsOf: [0x81, UInt8(content.count)])
        } else {
            out.append(contentsOf: [0x82, UInt8(content.count >> 8), UInt8(content.count & 0xFF)])
        }
        return out + content
    }
}
