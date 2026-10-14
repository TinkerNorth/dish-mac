// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Foundation

/// What a host says on the control stream, decoded from the plaintext. Every
/// field is little-endian but the termination reason.
public enum MoonlightEvent: Equatable, Sendable {
    /// RUMBLE_DATA: an unused u32, then the pad, low and high motors.
    case rumble(controller: UInt16, low: UInt16, high: UInt16)
    /// RUMBLE_TRIGGERS: the pad, left and right trigger motors.
    case rumbleTriggers(controller: UInt16, left: UInt16, right: UInt16)
    /// MOTION_EVENT: start (or, at rate 0, stop) sending this motion type.
    case motionRequest(controller: UInt16, rateHz: UInt16, type: UInt8)
    /// RGB_LED: the pad's lamp colour.
    case rgbLed(controller: UInt16, red: UInt8, green: UInt8, blue: UInt8)
    /// TERMINATION: the host is ending the session; nothing is recoverable
    /// after it.
    case termination(reason: UInt32)
    /// A type this client does not act on, the host's ping echo among them.
    case unknown(type: UInt16)
}

/// Nil when the buffer cannot hold the header, or a known type's body is
/// shorter than its fields: the advertised length is never trusted to
/// index past the end.
public func decodeMoonlightEvent(_ plaintext: Data) -> MoonlightEvent? {
    var reader = ByteReader(plaintext)
    guard let type = reader.u16LE(), reader.u16LE() != nil else { return nil }
    switch type {
    case MoonlightProtocol.eventRumbleData:
        guard reader.skip(4), let controller = reader.u16LE(), let low = reader.u16LE(), let high = reader.u16LE() else { return nil }
        return .rumble(controller: controller, low: low, high: high)
    case MoonlightProtocol.eventRumbleTriggers:
        guard let controller = reader.u16LE(), let left = reader.u16LE(), let right = reader.u16LE() else { return nil }
        return .rumbleTriggers(controller: controller, left: left, right: right)
    case MoonlightProtocol.eventMotion:
        guard let controller = reader.u16LE(), let rate = reader.u16LE(), let motionType = reader.u8() else { return nil }
        return .motionRequest(controller: controller, rateHz: rate, type: motionType)
    case MoonlightProtocol.eventRgbLed:
        guard let controller = reader.u16LE(), let red = reader.u8(), let green = reader.u8(), let blue = reader.u8() else { return nil }
        return .rgbLed(controller: controller, red: red, green: green, blue: blue)
    case MoonlightProtocol.packetTermination, MoonlightProtocol.packetTerminationLegacy:
        guard let reason = reader.u32BE() else { return nil }
        return .termination(reason: reason)
    default:
        return .unknown(type: type)
    }
}
