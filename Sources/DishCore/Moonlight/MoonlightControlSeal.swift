// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// The encrypted control-stream packet (Wolf control.hpp ControlEncryptedPacket):
//
//     [type u16 = 0x0001][len u16][seq u32][GCM tag 16][ciphertext]
//
// all little-endian, `len` counting the seq, the tag and the ciphertext.
// AES-128-GCM under the session's rikey, a 128-bit tag, no associated data,
// and an IV of sixteen zero bytes with the LOW BYTE of the sequence in byte 0
// and nothing else: the host assigns a u32 into a u8 element, so an IV that
// carried all four bytes agrees for the first 256 packets and never again.
// The IV therefore repeats every 256 packets on one key, the protocol's own
// property; what limits it is the rikey minted fresh for every launch.

import CryptoKit
import Foundation

public enum MoonlightControlSeal {
    public static let tagLength = 16
    public static let ivLength = 16

    public static func iv(seq: UInt32) -> Data {
        var iv = Data(count: ivLength)
        iv[0] = UInt8(truncatingIfNeeded: seq)
        return iv
    }

    /// `tag || ciphertext`, as the wire carries them; nil only for a key
    /// that is not an AES key, which a 16-byte rikey never is.
    public static func seal(key: SymmetricKey, seq: UInt32, plaintext: Data) -> Data? {
        guard let nonce = try? AES.GCM.Nonce(data: iv(seq: seq)),
              let box = try? AES.GCM.seal(plaintext, using: key, nonce: nonce) else { return nil }
        return box.tag + box.ciphertext
    }

    /// The plaintext, or nil for a short body or a tag that does not verify:
    /// a forged packet is dropped, never acted on.
    public static func open(key: SymmetricKey, seq: UInt32, tagThenCiphertext: Data) -> Data? {
        guard tagThenCiphertext.count >= tagLength,
              let nonce = try? AES.GCM.Nonce(data: iv(seq: seq)) else { return nil }
        let tag = tagThenCiphertext.prefix(tagLength)
        let ciphertext = tagThenCiphertext.dropFirst(tagLength)
        guard let box = try? AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag) else { return nil }
        return try? AES.GCM.open(box, using: key)
    }
}

public enum MoonlightControlPacket {
    public static let headerLength = 4
    public static let seqLength = 4

    public enum Opened: Equatable {
        case plaintext(Data)
        /// Too short, the wrong type, or a length the bytes do not back.
        case malformed
        /// Framed right, but the tag does not verify under this key and seq.
        case forged
    }

    public static func frame(seq: UInt32, tagThenCiphertext: Data) -> Data {
        var writer = ByteWriter(capacity: headerLength + seqLength + tagThenCiphertext.count)
        writer.u16LE(MoonlightProtocol.packetEncrypted)
        writer.u16LE(UInt16(truncatingIfNeeded: seqLength + tagThenCiphertext.count))
        writer.u32LE(seq)
        writer.append(tagThenCiphertext)
        return writer.data
    }

    public static func seal(key: SymmetricKey, seq: UInt32, plaintext: Data) -> Data? {
        MoonlightControlSeal.seal(key: key, seq: seq, plaintext: plaintext).map { frame(seq: seq, tagThenCiphertext: $0) }
    }

    /// The advertised length is checked against the bytes present before
    /// anything is read by it.
    public static func open(key: SymmetricKey, packet: Data) -> Opened {
        var reader = ByteReader(packet)
        guard reader.u16LE() == MoonlightProtocol.packetEncrypted,
              let length = reader.u16LE().map(Int.init),
              length >= seqLength + MoonlightControlSeal.tagLength,
              reader.remaining >= length,
              let seq = reader.u32LE(),
              let body = reader.take(length - seqLength) else { return .malformed }
        guard let plaintext = MoonlightControlSeal.open(key: key, seq: seq, tagThenCiphertext: body) else { return .forged }
        return .plaintext(plaintext)
    }
}

/// One session's outbound counter: every control packet the client sends,
/// whatever its kind, takes the next sequence number, starting at 0.
public struct MoonlightControlSealer: Equatable, Sendable {
    public let rikey: Data
    public private(set) var nextSeq: UInt32 = 0

    public init(rikey: Data) {
        self.rikey = rikey
    }

    public mutating func seal(_ plaintext: Data) -> Data? {
        let seq = nextSeq
        nextSeq &+= 1
        return MoonlightControlPacket.seal(key: SymmetricKey(data: rikey), seq: seq, plaintext: plaintext)
    }
}
