// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore

/// A 16-bit sequence on a Switch pad's right stick: the low byte on X and the
/// high byte on Y, each a raw value just past the stick's dead zone, read back
/// through the decoder's own scaling. The throw stays well inside the seed
/// reach, so the lane's learned calibration never moves.
struct SwitchSequence {
    static let firstRaw = UInt16(SwitchStickLimits.rawCenter + SwitchStickLimits.rawDeadzone + 1)

    private let byteOfAxis: [Int16: UInt8]

    init() {
        var table: [Int16: UInt8] = [:]
        for byte in UInt8.min ... UInt8.max {
            var reach = SwitchAxisReach()
            table[scaleSwitchStick(Self.raw(byte), reach: &reach)] = byte
        }
        byteOfAxis = table
    }

    static func raw(_ byte: UInt8) -> UInt16 {
        firstRaw + UInt16(byte)
    }

    /// The raw right stick that carries `sequence`.
    static func rawStick(_ sequence: UInt16) -> (x: UInt16, y: UInt16) {
        (raw(UInt8(truncatingIfNeeded: sequence)), raw(UInt8(truncatingIfNeeded: sequence >> 8)))
    }

    /// Every byte reads back as itself: the scaling kept them all apart.
    var isLossless: Bool {
        byteOfAxis.count == 256
    }

    /// The sequence a decoded report carries; nil for a stick it never sent.
    func sequence(rx: Int16, ry: Int16) -> UInt16? {
        guard let low = byteOfAxis[rx], let high = byteOfAxis[ry] else { return nil }
        return UInt16(high) << 8 | UInt16(low)
    }
}
