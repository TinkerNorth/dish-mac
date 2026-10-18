// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// The self-signed X.509 certificate around the dish's Moonlight RSA key, as
// every Moonlight client presents one (Wolf http-pairing.adoc): subject
// `CN=NVIDIA GameStream Client`, serial 1, twenty years, sha256WithRSA.
// Security.framework parses certificates but mints none, so the DER is
// written here, exactly the shapes an X.509 v3 certificate needs.

import Foundation
import Security

enum MoonlightCertificateMint {
    static let subjectCommonName = "NVIDIA GameStream Client"
    static let validitySeconds: TimeInterval = 20 * 365 * 24 * 3600
    private static let oidRsaEncryption: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01]
    private static let oidSha256WithRsaEncryption: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x0B]
    private static let oidCommonName: [UInt8] = [0x55, 0x04, 0x03]

    /// The DER of a certificate for this RSA key, signed by it; nil when the
    /// key cannot sign or export its public half.
    static func selfSigned(privateKey: SecKey, now: Date = Date()) -> Data? {
        guard let publicKey = SecKeyCopyPublicKey(privateKey),
              let pkcs1 = SecKeyCopyExternalRepresentation(publicKey, nil) as Data? else { return nil }
        let tbs = tbsCertificate(publicKeyPkcs1: pkcs1, now: now)
        let algorithm = SecKeyAlgorithm.rsaSignatureMessagePKCS1v15SHA256
        guard let signature = SecKeyCreateSignature(privateKey, algorithm, tbs as CFData, nil) as Data? else { return nil }
        return Asn1.sequence(tbs + signatureAlgorithm + Asn1.bitString(signature))
    }

    /// AlgorithmIdentifier for sha256WithRSAEncryption, parameters NULL (RFC 4055).
    static var signatureAlgorithm: Data {
        Asn1.sequence(Asn1.oid(oidSha256WithRsaEncryption) + Asn1.null)
    }

    private static func tbsCertificate(publicKeyPkcs1: Data, now: Date) -> Data {
        let name = Asn1.sequence(Asn1.set(Asn1.sequence(Asn1.oid(oidCommonName) + Asn1.utf8String(subjectCommonName))))
        let subjectPublicKeyInfo = Asn1.sequence(Asn1.sequence(Asn1.oid(oidRsaEncryption) + Asn1.null) + Asn1.bitString(publicKeyPkcs1))
        return Asn1.sequence(
            Asn1.explicitTag(0, Asn1.integer(2)) // version v3
                + Asn1.integer(1) // serial, as the reference clients number it
                + signatureAlgorithm
                + name // issuer == subject: self-signed
                + validity(now: now)
                + name
                + subjectPublicKeyInfo
        )
    }

    private static func validity(now: Date) -> Data {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        formatter.dateFormat = "yyMMddHHmmss'Z'"
        let notBefore = formatter.string(from: now.addingTimeInterval(-3600))
        let notAfter = formatter.string(from: now.addingTimeInterval(validitySeconds))
        return Asn1.sequence(Asn1.utcTime(notBefore) + Asn1.utcTime(notAfter))
    }
}

/// A DER writer for the shapes above and nothing more.
enum Asn1 {
    static let null = Data([0x05, 0x00])

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

    static func utf8String(_ value: String) -> Data {
        tagged(0x0C, Data(value.utf8))
    }

    static func utcTime(_ value: String) -> Data {
        tagged(0x17, Data(value.utf8))
    }

    static func oid(_ body: [UInt8]) -> Data {
        tagged(0x06, Data(body))
    }

    /// BIT STRING with no unused bits.
    static func bitString(_ content: Data) -> Data {
        tagged(0x03, Data([0x00]) + content)
    }

    /// Context-specific constructed [n] EXPLICIT wrapper.
    static func explicitTag(_ number: UInt8, _ content: Data) -> Data {
        tagged(0xA0 | number, content)
    }

    /// A small non-negative INTEGER.
    static func integer(_ value: UInt8) -> Data {
        value & 0x80 != 0 ? tagged(0x02, Data([0x00, value])) : tagged(0x02, Data([value]))
    }
}
