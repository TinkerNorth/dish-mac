// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Foundation

/// Decode a lower- or upper-case hex string into bytes. Returns nil if the
/// input length is odd or contains non-hex characters — callers use this to
/// validate server-issued tokens and keys before handing them to CryptoKit.
/// Per-nibble parse — `UInt8(_, radix:)` accepts a leading sign/whitespace.
func hexToBytes(_ hex: String) -> Data? {
    guard hex.count % 2 == 0 else { return nil }
    var out = Data()
    out.reserveCapacity(hex.count / 2)
    var high: UInt8?
    for char in hex.utf8 {
        guard let nibble = hexNibble(char) else { return nil }
        if let pending = high {
            out.append(pending << 4 | nibble)
            high = nil
        } else {
            high = nibble
        }
    }
    return out
}

private func hexNibble(_ char: UInt8) -> UInt8? {
    switch char {
    case 0x30 ... 0x39: char - 0x30
    case 0x61 ... 0x66: char - 0x61 + 10
    case 0x41 ... 0x46: char - 0x41 + 10
    default: nil
    }
}

extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

/// Big-endian encoders — the on-wire protocol is network-byte-order throughout
/// (matches the putBE16 / putBE32 helpers in `satellite_jni.cpp`).
func putBE16(_ value: UInt16, into buf: inout [UInt8], at offset: Int) {
    buf[offset] = UInt8(truncatingIfNeeded: value >> 8)
    buf[offset + 1] = UInt8(truncatingIfNeeded: value)
}

func putBE32(_ value: UInt32, into buf: inout [UInt8], at offset: Int) {
    buf[offset] = UInt8(truncatingIfNeeded: value >> 24)
    buf[offset + 1] = UInt8(truncatingIfNeeded: value >> 16)
    buf[offset + 2] = UInt8(truncatingIfNeeded: value >> 8)
    buf[offset + 3] = UInt8(truncatingIfNeeded: value)
}
