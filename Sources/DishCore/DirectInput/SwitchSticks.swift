// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// A Switch pad's 12-bit sticks, read the way dish-android's
// `scaleSwitchStickAuto` reads them: no factory calibration, a raw dead zone
// that absorbs the per-unit resting offset, and each side of each axis
// stretched to the rail against the longest throw it has shown. The wire is
// up-positive and so is the pad, so nothing is inverted.

import Foundation

/// The longest throw past the dead zone each side of one axis has shown,
/// seeded short so an untaught stick still reaches the rail.
public struct SwitchAxisReach: Equatable, Sendable {
    public static let seed: Int32 = 1000

    public var positive: Int32
    public var negative: Int32

    public init(positive: Int32 = SwitchAxisReach.seed, negative: Int32 = SwitchAxisReach.seed) {
        self.positive = positive
        self.negative = negative
    }
}

/// What a reader keeps per device between reports: the four axes' reach.
public struct SwitchStickCalibration: Equatable, Sendable {
    public var lx = SwitchAxisReach()
    public var ly = SwitchAxisReach()
    public var rx = SwitchAxisReach()
    public var ry = SwitchAxisReach()

    public init() {}
}

public enum SwitchStickLimits {
    public static let rawCenter: Int32 = 2048
    public static let rawDeadzone: Int32 = 320
    public static let positiveRail: Int32 = 32767
    public static let negativeRail: Int32 = 32768
}

/// Two 12-bit values packed little-endian into three bytes: the first is
/// byte 0 plus the low nibble of byte 1, the second the high nibble of byte 1
/// plus byte 2.
func unpackTwo12Bit(_ b0: UInt8, _ b1: UInt8, _ b2: UInt8) -> (first: UInt16, second: UInt16) {
    let low = UInt16(b0)
    let middle = UInt16(b1)
    let high = UInt16(b2)
    let first = low | ((middle & 0x0F) << 8)
    let second = (middle >> 4) | (high << 4)
    return (first, second)
}

/// A deflection past the dead zone, against the longest one this side has
/// seen, learning a longer throw on the way.
private func stretchToRail(_ deflection: Int32, reach: inout Int32, rail: Int32) -> Int32 {
    reach = max(reach, deflection)
    return deflection * rail / reach
}

/// One 12-bit axis on the wire's scale.
public func scaleSwitchStick(_ raw12: UInt16, reach: inout SwitchAxisReach) -> Int16 {
    let centered = Int32(raw12) - SwitchStickLimits.rawCenter
    let magnitude = abs(centered)
    let atRest = magnitude <= SwitchStickLimits.rawDeadzone
    if atRest { return 0 }
    let deflection = magnitude - SwitchStickLimits.rawDeadzone
    let pushed = centered >= 0
    if pushed {
        return Int16(clamping: stretchToRail(deflection, reach: &reach.positive, rail: SwitchStickLimits.positiveRail))
    }
    let pulled = stretchToRail(deflection, reach: &reach.negative, rail: SwitchStickLimits.negativeRail)
    return Int16(clamping: -pulled)
}

/// One stick from its three packed bytes at `offset`.
func decodeSwitchStick(
    _ report: UnsafeBufferPointer<UInt8>,
    at offset: Int,
    x: inout SwitchAxisReach,
    y: inout SwitchAxisReach
) -> (x: Int16, y: Int16) {
    let raw = unpackTwo12Bit(report[offset], report[offset + 1], report[offset + 2])
    let scaledX = scaleSwitchStick(raw.first, reach: &x)
    let scaledY = scaleSwitchStick(raw.second, reach: &y)
    return (scaledX, scaledY)
}
