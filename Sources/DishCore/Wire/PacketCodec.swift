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

    /// `frame`'s header written into the first 8 bytes of `datagram`; the
    /// box follows it there.
    public static func writeHeader(token: UInt32, counter: UInt32, into datagram: UnsafeMutableRawBufferPointer) {
        storeU32BE(token, into: datagram, at: 0)
        storeU32BE(counter, into: datagram, at: 4)
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

    /// The cleartext header of one datagram, read where it lies: the receive
    /// loop's buffer. Nil when the datagram cannot carry a sealed message,
    /// as `parse` decides.
    public static func parseHeader(_ packet: UnsafeRawBufferPointer) -> Header? {
        guard packet.count >= ProtocolConstants.headerSize + ProtocolConstants.authTagSize else { return nil }
        return Header(token: loadU32BE(packet, at: 0), counter: loadU32BE(packet, at: 4))
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

    /// `innerFrame`'s header written into the first 4 bytes of `inner`; the
    /// payload follows it there.
    public static func writeInnerHeader(msgType: UInt16, payloadCount: Int, into inner: UnsafeMutableRawBufferPointer) {
        precondition(payloadCount <= Int(UInt16.max), "inner payload exceeds the u16 length field")
        inner[0] = UInt8(truncatingIfNeeded: msgType >> 8)
        inner[1] = UInt8(truncatingIfNeeded: msgType)
        inner[2] = UInt8(truncatingIfNeeded: payloadCount >> 8)
        inner[3] = UInt8(truncatingIfNeeded: payloadCount)
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

public extension PacketCodec {
    /// `parseInner` without the copy: the payload is a slice of `plaintext`,
    /// so it is read from its `startIndex`, as every payload parser here
    /// reads. Nil when shorter than the inner header.
    static func parseInnerInPlace(_ plaintext: Data) -> InnerMessage? {
        guard plaintext.count >= ProtocolConstants.innerHeaderSize else { return nil }
        return InnerMessage(
            msgType: plaintext.u16BE(0),
            declaredLength: plaintext.u16BE(2),
            payload: plaintext[(plaintext.startIndex + ProtocolConstants.innerHeaderSize)...]
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

func storeU32BE(_ value: UInt32, into bytes: UnsafeMutableRawBufferPointer, at offset: Int) {
    bytes[offset] = UInt8(truncatingIfNeeded: value >> 24)
    bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 16)
    bytes[offset + 2] = UInt8(truncatingIfNeeded: value >> 8)
    bytes[offset + 3] = UInt8(truncatingIfNeeded: value)
}

func loadU32BE(_ bytes: UnsafeRawBufferPointer, at offset: Int) -> UInt32 {
    UInt32(bytes[offset]) << 24
        | UInt32(bytes[offset + 1]) << 16
        | UInt32(bytes[offset + 2]) << 8
        | UInt32(bytes[offset + 3])
}

/// Reads that count from a payload's own start, so a slice of a plaintext
/// parses as the whole would, with nothing copied.
extension Data {
    func byte(_ offset: Int) -> UInt8 {
        self[startIndex + offset]
    }

    func u16BE(_ offset: Int) -> UInt16 {
        UInt16(byte(offset)) << 8 | UInt16(byte(offset + 1))
    }
}
