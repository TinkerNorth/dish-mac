// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Foundation

/// The Moonlight wire is little-endian except for the handful of fields the
/// protocol mandates big-endian; each call site spells its order out.
package struct ByteWriter {
    package private(set) var bytes: [UInt8] = []

    package init(capacity: Int) {
        bytes.reserveCapacity(capacity)
    }

    package var data: Data {
        Data(bytes)
    }

    package mutating func u8(_ value: UInt8) {
        bytes.append(value)
    }

    package mutating func u16LE(_ value: UInt16) {
        bytes.append(UInt8(truncatingIfNeeded: value))
        bytes.append(UInt8(truncatingIfNeeded: value >> 8))
    }

    package mutating func u16BE(_ value: UInt16) {
        bytes.append(UInt8(truncatingIfNeeded: value >> 8))
        bytes.append(UInt8(truncatingIfNeeded: value))
    }

    package mutating func u32LE(_ value: UInt32) {
        for shift in stride(from: 0, to: 32, by: 8) {
            bytes.append(UInt8(truncatingIfNeeded: value >> UInt32(shift)))
        }
    }

    package mutating func u32BE(_ value: UInt32) {
        for shift in stride(from: 24, through: 0, by: -8) {
            bytes.append(UInt8(truncatingIfNeeded: value >> UInt32(shift)))
        }
    }

    package mutating func i16LE(_ value: Int16) {
        u16LE(UInt16(bitPattern: value))
    }

    package mutating func i16BE(_ value: Int16) {
        u16BE(UInt16(bitPattern: value))
    }

    /// Wolf's netfloat: IEEE-754 single, little-endian.
    package mutating func f32LE(_ value: Float) {
        u32LE(value.bitPattern)
    }

    package mutating func append(_ data: Data) {
        bytes.append(contentsOf: data)
    }
}

/// A bounds-checked reader: every read is optional, so a truncated or lying
/// frame ends a decode with nil instead of a read past the end.
package struct ByteReader {
    private let bytes: [UInt8]
    private(set) var offset = 0

    package init(_ data: Data) {
        bytes = [UInt8](data)
    }

    package var remaining: Int {
        bytes.count - offset
    }

    package mutating func u8() -> UInt8? {
        guard remaining >= 1 else { return nil }
        defer { offset += 1 }
        return bytes[offset]
    }

    package mutating func u16LE() -> UInt16? {
        guard remaining >= 2 else { return nil }
        defer { offset += 2 }
        return UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    package mutating func u16BE() -> UInt16? {
        guard remaining >= 2 else { return nil }
        defer { offset += 2 }
        return UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
    }

    package mutating func u32LE() -> UInt32? {
        guard remaining >= 4 else { return nil }
        defer { offset += 4 }
        return (0 ..< 4).reduce(UInt32(0)) { acc, index in acc | UInt32(bytes[offset + index]) << UInt32(index * 8) }
    }

    package mutating func u32BE() -> UInt32? {
        guard remaining >= 4 else { return nil }
        defer { offset += 4 }
        return (0 ..< 4).reduce(UInt32(0)) { acc, index in acc << 8 | UInt32(bytes[offset + index]) }
    }

    package mutating func skip(_ count: Int) -> Bool {
        guard remaining >= count else { return false }
        offset += count
        return true
    }

    package mutating func take(_ count: Int) -> Data? {
        guard remaining >= count else { return nil }
        defer { offset += count }
        return Data(bytes[offset ..< offset + count])
    }
}
