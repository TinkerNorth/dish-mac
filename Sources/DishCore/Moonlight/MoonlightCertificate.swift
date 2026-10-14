// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// The two things the pairing needs from an X.509 certificate without any
// framework: its signature bytes, which both ends hash, and its DER, which
// the trust pin fingerprints. A certificate is `SEQUENCE { tbsCertificate,
// signatureAlgorithm, signatureValue BIT STRING }`; the walk reads the outer
// shape and nothing inside the first two.

import Foundation

public enum MoonlightCertificate {
    public static func der(fromPem pem: String) -> Data? {
        let body = pem
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("-----") }
            .joined()
        guard !body.isEmpty else { return nil }
        return Data(base64Encoded: body)
    }

    /// The PEM a host expects in phase 1: 64 columns, the usual armour.
    public static func pem(fromDer der: Data) -> String {
        let base64 = der.base64EncodedString()
        let lines = stride(from: 0, to: base64.count, by: 64).map { start -> String in
            let from = base64.index(base64.startIndex, offsetBy: start)
            let upTo = base64.index(from, offsetBy: 64, limitedBy: base64.endIndex) ?? base64.endIndex
            return String(base64[from ..< upTo])
        }
        return (["-----BEGIN CERTIFICATE-----"] + lines + ["-----END CERTIFICATE-----"]).joined(separator: "\n") + "\n"
    }

    /// The signatureValue's bytes, the leading unused-bits byte dropped.
    public static func signatureBytes(der: Data) -> Data? {
        var outer = DerReader(der)
        guard let certificate = outer.element(), certificate.tag == DerReader.sequence else { return nil }
        var inner = DerReader(certificate.content)
        guard let tbs = inner.element(), tbs.tag == DerReader.sequence,
              let algorithm = inner.element(), algorithm.tag == DerReader.sequence,
              let signature = inner.element(), signature.tag == DerReader.bitString,
              !signature.content.isEmpty else { return nil }
        return signature.content.dropFirst()
    }

    public static func fingerprintHex(der: Data) -> String {
        sha256FingerprintHex(der)
    }
}

/// One DER element at a time: tag, definite length (short or long form), content.
struct DerReader {
    static let sequence: UInt8 = 0x30
    static let bitString: UInt8 = 0x03

    private var reader: ByteReader

    init(_ data: Data) {
        reader = ByteReader(data)
    }

    mutating func element() -> (tag: UInt8, content: Data)? {
        guard let tag = reader.u8(), let first = reader.u8() else { return nil }
        guard let length = first < 0x80 ? Int(first) : longLength(bytes: Int(first & 0x7F)) else { return nil }
        guard let content = reader.take(length) else { return nil }
        return (tag, content)
    }

    private mutating func longLength(bytes: Int) -> Int? {
        guard (1 ... 4).contains(bytes) else { return nil }
        var length = 0
        for _ in 0 ..< bytes {
            guard let byte = reader.u8() else { return nil }
            length = length << 8 | Int(byte)
        }
        return length
    }
}
