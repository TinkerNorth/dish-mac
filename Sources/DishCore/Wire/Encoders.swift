// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// Inner-payload encoders (client to server) and decoders (server to client)
// for the UDP streams. Every multi-byte field's endianness is written out,
// because the receiver decodes with explicit byte shifts.

import Foundation

/// Stateless payload encoders for the up-direction streams. Each returns the
/// inner payload only — wrap with `PacketCodec.innerFrame` + `SessionCrypto.seal`.
public enum Encoders {

    /// MSG_INPUT (0x0001): `ctrlIdx(1) + XUSB_REPORT(12 LE)` = 13 bytes.
    public static func inputPayload(controllerIndex: UInt8, report: GamepadReport) -> Data {
        var out = [UInt8](repeating: 0, count: ProtocolConstants.inputPayloadBytes)
        out[0] = controllerIndex
        out[1] = UInt8(truncatingIfNeeded: report.buttons)
        out[2] = UInt8(truncatingIfNeeded: report.buttons >> 8)
        out[3] = report.lt
        out[4] = report.rt
        storeLE16(report.lx, into: &out, at: 5)
        storeLE16(report.ly, into: &out, at: 7)
        storeLE16(report.rx, into: &out, at: 9)
        storeLE16(report.ry, into: &out, at: 11)
        return Data(out)
    }

    /// MSG_MOTION (0x000A): `ctrlIdx(1) + gyroX/Y/Z(3 × i16 LE) +
    /// accelX/Y/Z(3 × i16 LE) + timestampDeltaUs(u32 LE)` = 17 bytes.
    /// `timestampDeltaUs` is the time since this controller's previous motion
    /// packet, 0 on the first.
    public static func motionPayload(controllerIndex: UInt8, sample: MotionSample, timestampDeltaUs: UInt32) -> Data {
        var out = [UInt8](repeating: 0, count: ProtocolConstants.motionPayloadBytes)
        out[0] = controllerIndex
        storeLE16(sample.gyroX, into: &out, at: 1)
        storeLE16(sample.gyroY, into: &out, at: 3)
        storeLE16(sample.gyroZ, into: &out, at: 5)
        storeLE16(sample.accelX, into: &out, at: 7)
        storeLE16(sample.accelY, into: &out, at: 9)
        storeLE16(sample.accelZ, into: &out, at: 11)
        storeLE32(timestampDeltaUs, into: &out, at: 13)
        return Data(out)
    }

    /// MSG_BATTERY (0x000B): `ctrlIdx(1) + level(1) + status(1)` = 3 bytes.
    /// `level` is 0...100, or `ProtocolConstants.batteryLevelUnknown` for a
    /// status-only reading.
    public static func batteryPayload(controllerIndex: UInt8, level: UInt8, status: BatteryStatus) -> Data {
        Data([controllerIndex, level, status.rawValue])
    }

    /// MSG_TOUCHPAD (0x000C): `ctrlIdx(1) + flags(1) + f0(id1 + x2 + y2) +
    /// f1(id1 + x2 + y2) + eventTimeMs(u32 LE @ offset 12)` = 16 bytes.
    /// `flags` bit 0 = finger0 active, bit 1 = finger1 active, bit 2 = the
    /// clickable pad. The server drops a body shorter than 16 bytes.
    public static func touchpadPayload(
        controllerIndex: UInt8,
        sample: TouchpadSample,
        eventTimeMs: UInt32
    ) -> Data {
        var out = [UInt8](repeating: 0, count: 1 + ProtocolConstants.touchpadPayloadBytes)
        out[0] = controllerIndex
        var flags: UInt8 = 0
        if sample.finger0.active { flags |= 0x01 }
        if sample.finger1.active { flags |= 0x02 }
        if sample.buttonPressed { flags |= 0x04 }
        out[1] = flags
        out[2] = sample.finger0.id
        storeLE16(sample.finger0.x, into: &out, at: 3)
        storeLE16(sample.finger0.y, into: &out, at: 5)
        out[7] = sample.finger1.id
        storeLE16(sample.finger1.x, into: &out, at: 8)
        storeLE16(sample.finger1.y, into: &out, at: 10)
        storeLE32(eventTimeMs, into: &out, at: 12)
        return Data(out)
    }

    // MARK: - Private little-endian stores (zero-based [UInt8] offsets)

    private static func storeLE16(_ value: Int16, into buf: inout [UInt8], at offset: Int) {
        let unsigned = UInt16(bitPattern: value)
        buf[offset] = UInt8(truncatingIfNeeded: unsigned)
        buf[offset + 1] = UInt8(truncatingIfNeeded: unsigned >> 8)
    }

    private static func storeLE32(_ value: UInt32, into buf: inout [UInt8], at offset: Int) {
        buf[offset] = UInt8(truncatingIfNeeded: value)
        buf[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
        buf[offset + 2] = UInt8(truncatingIfNeeded: value >> 16)
        buf[offset + 3] = UInt8(truncatingIfNeeded: value >> 24)
    }
}

/// Decoded enriched heartbeat ack (MSG_HEARTBEAT_ACK 0x0003):
/// `backendAvailable(1) + totalActiveControllers(1) + epoch(u16 BE) +
/// activeBitmap(u16 BE)`. The epoch/bitmap pair drives the reconcile loop
/// (contract §Enriched heartbeat ack).
public struct HeartbeatAck: Equatable, Sendable {
    public var backendAvailable: Bool
    public var activeCount: UInt8
    public var epoch: UInt16
    public var bitmap: UInt16

    public init(backendAvailable: Bool, activeCount: UInt8, epoch: UInt16, bitmap: UInt16) {
        self.backendAvailable = backendAvailable
        self.activeCount = activeCount
        self.epoch = epoch
        self.bitmap = bitmap
    }

    /// Parse the inner payload (after the 4-byte type+length header). Nil
    /// when shorter than 6 bytes — a bare ack from a pre-protocol-1 server
    /// still counts for liveness, just not for reconcile.
    public static func parse(_ payload: Data) -> HeartbeatAck? {
        let bytes = [UInt8](payload)
        guard bytes.count >= ProtocolConstants.heartbeatAckPayloadBytes else { return nil }
        return HeartbeatAck(
            backendAvailable: bytes[0] != 0,
            activeCount: bytes[1],
            epoch: readU16BE(bytes, at: 2),
            bitmap: readU16BE(bytes, at: 4)
        )
    }
}

/// Decoded MSG_RUMBLE (0x0009) — motor magnitudes plus a server-stamped
/// duration (500 ms when the host API has no duration; refresh arrives before
/// expiry; stop = magnitudes 0,0). The light bar is a separate return path.
public struct RumbleCommand: Equatable, Sendable {
    public var controllerIndex: UInt8
    public var strongMagnitude: UInt16
    public var weakMagnitude: UInt16
    public var durationMs: UInt16

    public init(controllerIndex: UInt8, strongMagnitude: UInt16, weakMagnitude: UInt16, durationMs: UInt16) {
        self.controllerIndex = controllerIndex
        self.strongMagnitude = strongMagnitude
        self.weakMagnitude = weakMagnitude
        self.durationMs = durationMs
    }

    /// Parse the fixed 7-byte payload `ctrlIdx(1) + strong(2 BE) +
    /// weak(2 BE) + durMs(2 BE)`; nil on truncation.
    public static func parse(_ payload: Data) -> RumbleCommand? {
        let bytes = [UInt8](payload)
        guard bytes.count >= ProtocolConstants.rumblePayloadBytes else { return nil }
        return RumbleCommand(
            controllerIndex: bytes[0],
            strongMagnitude: readU16BE(bytes, at: 1),
            weakMagnitude: readU16BE(bytes, at: 3),
            durationMs: readU16BE(bytes, at: 5)
        )
    }
}

/// Decoded MSG_LIGHTBAR (0x000D) — dedicated colour stream, independent from
/// rumble so games that only change colour still drive the LED on the dish.
public struct LightbarCommand: Equatable, Sendable {
    public var controllerIndex: UInt8
    public var r: UInt8
    public var g: UInt8
    public var b: UInt8

    public init(controllerIndex: UInt8, r: UInt8, g: UInt8, b: UInt8) {
        self.controllerIndex = controllerIndex
        self.r = r
        self.g = g
        self.b = b
    }

    /// Parse the 4-byte payload `ctrlIdx(1) + r(1) + g(1) + b(1)`; nil on
    /// truncation.
    public static func parse(_ payload: Data) -> LightbarCommand? {
        let bytes = [UInt8](payload)
        guard bytes.count >= ProtocolConstants.lightbarPayloadBytes else { return nil }
        return LightbarCommand(controllerIndex: bytes[0], r: bytes[1], g: bytes[2], b: bytes[3])
    }
}
