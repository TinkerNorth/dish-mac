// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Foundation

/// Decode a lower- or upper-case hex string into bytes. Returns nil if the
/// input length is odd or contains non-hex characters — callers use this to
/// validate server-issued tokens and keys before handing them to CryptoKit.
func hexToBytes(_ hex: String) -> Data? {
    guard hex.count % 2 == 0 else { return nil }
    var out = Data()
    out.reserveCapacity(hex.count / 2)
    var idx = hex.startIndex
    while idx < hex.endIndex {
        let next = hex.index(idx, offsetBy: 2)
        guard let byte = UInt8(hex[idx..<next], radix: 16) else { return nil }
        out.append(byte)
        idx = next
    }
    return out
}

extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}

/// Big-endian encoders — the on-wire protocol is network-byte-order throughout
/// (matches the putBE16 / putBE32 helpers in `satellite_jni.cpp`).
func putBE16(_ value: UInt16, into buf: inout [UInt8], at offset: Int) {
    buf[offset]     = UInt8(truncatingIfNeeded: value >> 8)
    buf[offset + 1] = UInt8(truncatingIfNeeded: value)
}

func putBE32(_ value: UInt32, into buf: inout [UInt8], at offset: Int) {
    buf[offset]     = UInt8(truncatingIfNeeded: value >> 24)
    buf[offset + 1] = UInt8(truncatingIfNeeded: value >> 16)
    buf[offset + 2] = UInt8(truncatingIfNeeded: value >> 8)
    buf[offset + 3] = UInt8(truncatingIfNeeded: value)
}
