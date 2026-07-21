// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// Pure framing for the UDP data plane (contract §Crypto packet format):
//
//     cleartext header : token(4 BE) | counter(4 BE)
//     box              : ChaCha20-Poly1305 ciphertext + 16-byte tag
//     inner plaintext  : msgType(2 BE) | msgLen(2 BE) | payload
//
// Build + parse only — the AEAD itself lives in SessionCrypto, and socket IO
// stays in the imperative shell. Mirrors dish-linux SatelliteClient's
// sendEncrypted/processIncoming framing byte-for-byte.

import Foundation

/// Stateless builder/parser for the cleartext packet header and the inner
/// message frame.
public enum PacketCodec {

    /// The cleartext 8-byte prefix of every datagram: session token + the
    /// sender's per-direction counter (both big-endian).
    public struct Header: Equatable, Sendable {
        public var token: UInt32
        public var counter: UInt32

        public init(token: UInt32, counter: UInt32) {
            self.token = token
            self.counter = counter
        }
    }

    /// One decrypted inner frame. `payload` is every byte after the 4-byte
    /// header — like the sibling clients we parse by REMAINING length, so a
    /// packet from a newer server with trailing extension bytes still parses;
    /// `declaredLength` carries the sender's `msgLen` for callers that want
    /// the stricter satellite-receiver check.
    public struct InnerMessage: Equatable, Sendable {
        public var msgType: UInt16
        public var declaredLength: UInt16
        public var payload: Data

        public init(msgType: UInt16, declaredLength: UInt16, payload: Data) {
            self.msgType = msgType
            self.declaredLength = declaredLength
            self.payload = payload
        }
    }

    /// Assemble one datagram: `token(4 BE) | counter(4 BE) | box`.
    /// `box` is `SessionCrypto.seal`'s output (ciphertext + tag).
    public static func frame(token: UInt32, counter: UInt32, box: Data) -> Data {
        var out = Data(capacity: ProtocolConstants.headerSize + box.count)
        out.append(contentsOf: SessionCrypto.bigEndianBytes(token))
        out.append(contentsOf: SessionCrypto.bigEndianBytes(counter))
        out.append(box)
        return out
    }

    /// Split one datagram into its cleartext header + box. Returns nil when
    /// the datagram cannot possibly carry a sealed message (shorter than
    /// header + tag) — the receive loop drops it without touching the AEAD.
    public static func parse(_ packet: Data) -> (header: Header, box: Data)? {
        guard packet.count >= ProtocolConstants.headerSize + ProtocolConstants.authTagSize else { return nil }
        let head = [UInt8](packet.prefix(ProtocolConstants.headerSize))
        let header = Header(
            token: readU32BE(head, at: 0),
            counter: readU32BE(head, at: 4)
        )
        return (header, Data(packet.dropFirst(ProtocolConstants.headerSize)))
    }

    /// Assemble one inner plaintext frame: `msgType(2 BE) | msgLen(2 BE) |
    /// payload`. `msgLen` is always the true payload length — the satellite
    /// receiver validates it.
    public static func innerFrame(msgType: UInt16, payload: Data) -> Data {
        precondition(payload.count <= Int(UInt16.max), "inner payload exceeds the u16 length field")
        var out = Data(capacity: ProtocolConstants.innerHeaderSize + payload.count)
        out.append(UInt8(truncatingIfNeeded: msgType >> 8))
        out.append(UInt8(truncatingIfNeeded: msgType))
        let length = UInt16(payload.count)
        out.append(UInt8(truncatingIfNeeded: length >> 8))
        out.append(UInt8(truncatingIfNeeded: length))
        out.append(payload)
        return out
    }

    /// Split one decrypted plaintext into an `InnerMessage`. Returns nil when
    /// shorter than the 4-byte inner header.
    public static func parseInner(_ plaintext: Data) -> InnerMessage? {
        guard plaintext.count >= ProtocolConstants.innerHeaderSize else { return nil }
        let head = [UInt8](plaintext.prefix(ProtocolConstants.innerHeaderSize))
        return InnerMessage(
            msgType: readU16BE(head, at: 0),
            declaredLength: readU16BE(head, at: 2),
            payload: Data(plaintext.dropFirst(ProtocolConstants.innerHeaderSize))
        )
    }
}

// MARK: - Module-internal big-endian readers (zero-based [UInt8] offsets)

func readU16BE(_ bytes: [UInt8], at offset: Int) -> UInt16 {
    UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
}

func readU32BE(_ bytes: [UInt8], at offset: Int) -> UInt32 {
    UInt32(bytes[offset]) << 24
        | UInt32(bytes[offset + 1]) << 16
        | UInt32(bytes[offset + 2]) << 8
        | UInt32(bytes[offset + 3])
}
