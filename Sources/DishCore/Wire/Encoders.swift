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

    /// MSG_INPUT (0x0001): `ctrlIdx(1) + XUSB_REPORT(12 LE)` = 13 bytes, and
    /// on a session settled on version 4 or later `+ extButtons(u32 LE)` =
    /// 17 bytes, the reserved bits written as 0.
    public static func inputPayload(controllerIndex: UInt8, report: GamepadReport, settledVersion: Int) -> Data {
        payload(ProtocolConstants.inputPayloadBytes(settledVersion: settledVersion)) { out in
            writeInputPayload(controllerIndex: controllerIndex, report: report, settledVersion: settledVersion, into: out)
        }
    }

    /// `inputPayload` written into the first 13 or 17 bytes of `out`.
    public static func writeInputPayload(
        controllerIndex: UInt8,
        report: GamepadReport,
        settledVersion: Int,
        into out: UnsafeMutableRawBufferPointer
    ) {
        out[0] = controllerIndex
        out[1] = UInt8(truncatingIfNeeded: report.buttons)
        out[2] = UInt8(truncatingIfNeeded: report.buttons >> 8)
        out[3] = report.lt
        out[4] = report.rt
        storeLE16(report.lx, into: out, at: 5)
        storeLE16(report.ly, into: out, at: 7)
        storeLE16(report.rx, into: out, at: 9)
        storeLE16(report.ry, into: out, at: 11)
        guard ProtocolConstants.settledSpeaksV4(settledVersion) else { return }
        storeLE32(report.extButtons & ProtocolConstants.extButtonsKnownMask, into: out, at: ProtocolConstants.inputPayloadBytes)
    }

    /// MSG_MOTION (0x000A): `ctrlIdx(1) + gyroX/Y/Z(3 × i16 LE) +
    /// accelX/Y/Z(3 × i16 LE) + timestampDeltaUs(u32 LE)` = 17 bytes.
    /// `timestampDeltaUs` is the time since this controller's previous motion
    /// packet, 0 on the first.
    public static func motionPayload(controllerIndex: UInt8, sample: MotionSample, timestampDeltaUs: UInt32) -> Data {
        payload(ProtocolConstants.motionPayloadBytes) {
            writeMotionPayload(controllerIndex: controllerIndex, sample: sample, timestampDeltaUs: timestampDeltaUs, into: $0)
        }
    }

    /// `motionPayload` written into the first 17 bytes of `out`.
    public static func writeMotionPayload(
        controllerIndex: UInt8,
        sample: MotionSample,
        timestampDeltaUs: UInt32,
        into out: UnsafeMutableRawBufferPointer
    ) {
        out[0] = controllerIndex
        storeLE16(sample.gyroX, into: out, at: 1)
        storeLE16(sample.gyroY, into: out, at: 3)
        storeLE16(sample.gyroZ, into: out, at: 5)
        storeLE16(sample.accelX, into: out, at: 7)
        storeLE16(sample.accelY, into: out, at: 9)
        storeLE16(sample.accelZ, into: out, at: 11)
        storeLE32(timestampDeltaUs, into: out, at: 13)
    }

    /// MSG_BATTERY (0x000B): `ctrlIdx(1) + level(1) + status(1)` = 3 bytes.
    /// `level` is 0...100, or `ProtocolConstants.batteryLevelUnknown` for a
    /// status-only reading.
    public static func batteryPayload(controllerIndex: UInt8, level: UInt8, status: BatteryStatus) -> Data {
        Data([controllerIndex, level, status.rawValue])
    }

    /// `batteryPayload` written into the first 3 bytes of `out`.
    public static func writeBatteryPayload(
        controllerIndex: UInt8,
        level: UInt8,
        status: BatteryStatus,
        into out: UnsafeMutableRawBufferPointer
    ) {
        out[0] = controllerIndex
        out[1] = level
        out[2] = status.rawValue
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
        payload(1 + ProtocolConstants.touchpadPayloadBytes) {
            writeTouchpadPayload(controllerIndex: controllerIndex, sample: sample, eventTimeMs: eventTimeMs, into: $0)
        }
    }

    /// `touchpadPayload` written into the first 16 bytes of `out`.
    public static func writeTouchpadPayload(
        controllerIndex: UInt8,
        sample: TouchpadSample,
        eventTimeMs: UInt32,
        into out: UnsafeMutableRawBufferPointer
    ) {
        out[0] = controllerIndex
        var flags: UInt8 = 0
        if sample.finger0.active { flags |= 0x01 }
        if sample.finger1.active { flags |= 0x02 }
        if sample.buttonPressed { flags |= 0x04 }
        out[1] = flags
        out[2] = sample.finger0.id
        storeLE16(sample.finger0.x, into: out, at: 3)
        storeLE16(sample.finger0.y, into: out, at: 5)
        out[7] = sample.finger1.id
        storeLE16(sample.finger1.x, into: out, at: 8)
        storeLE16(sample.finger1.y, into: out, at: 10)
        storeLE32(eventTimeMs, into: out, at: 12)
    }

    /// MSG_TOUCHPAD (0x000C) in its version-2 POINTER shape: `ctrlIdx(1) +
    /// fingerFlags(1) + buttons(1) + f0(id1 + x2 + y2) + f1(id1 + x2 + y2) +
    /// eventTimeMs(u32 LE @ 13) + scrollV(i16 LE @ 17)` = 19 bytes. The pad's
    /// click rides the buttons byte as the left button; `scrollV` is an
    /// event in 120ths of a notch, 0 on a resend. Only a session settled on
    /// version 2 or later may send this; the receiver tells the two shapes
    /// apart by length.
    public static func pointerPayload(
        controllerIndex: UInt8,
        sample: TouchpadSample,
        eventTimeMs: UInt32,
        scrollV: Int16 = 0
    ) -> Data {
        payload(1 + ProtocolConstants.pointerPayloadBytes) {
            writePointerPayload(controllerIndex: controllerIndex, sample: sample, eventTimeMs: eventTimeMs, scrollV: scrollV, into: $0)
        }
    }

    /// `pointerPayload` written into the first 19 bytes of `out`.
    public static func writePointerPayload(
        controllerIndex: UInt8,
        sample: TouchpadSample,
        eventTimeMs: UInt32,
        scrollV: Int16 = 0,
        into out: UnsafeMutableRawBufferPointer
    ) {
        out[0] = controllerIndex
        out[1] = pointerFingerFlags(sample)
        out[2] = sample.buttonPressed ? ProtocolConstants.pointerButtonLeft : 0
        out[3] = sample.finger0.id
        storeLE16(sample.finger0.x, into: out, at: 4)
        storeLE16(sample.finger0.y, into: out, at: 6)
        out[8] = sample.finger1.id
        storeLE16(sample.finger1.x, into: out, at: 9)
        storeLE16(sample.finger1.y, into: out, at: 11)
        storeLE32(eventTimeMs, into: out, at: 13)
        storeLE16(scrollV, into: out, at: 17)
    }

    private static func pointerFingerFlags(_ sample: TouchpadSample) -> UInt8 {
        var flags: UInt8 = 0
        if sample.finger0.active { flags |= ProtocolConstants.pointerFinger0Active }
        if sample.finger1.active { flags |= ProtocolConstants.pointerFinger1Active }
        return flags
    }

    // MARK: - Private stores (zero-based offsets into the payload)

    private static func payload(_ count: Int, _ write: (UnsafeMutableRawBufferPointer) -> Void) -> Data {
        var out = Data(count: count)
        out.withUnsafeMutableBytes { write($0) }
        return out
    }

    private static func storeLE16(_ value: Int16, into out: UnsafeMutableRawBufferPointer, at offset: Int) {
        let unsigned = UInt16(bitPattern: value)
        out[offset] = UInt8(truncatingIfNeeded: unsigned)
        out[offset + 1] = UInt8(truncatingIfNeeded: unsigned >> 8)
    }

    private static func storeLE32(_ value: UInt32, into out: UnsafeMutableRawBufferPointer, at offset: Int) {
        out[offset] = UInt8(truncatingIfNeeded: value)
        out[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
        out[offset + 2] = UInt8(truncatingIfNeeded: value >> 16)
        out[offset + 3] = UInt8(truncatingIfNeeded: value >> 24)
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
        guard payload.count >= ProtocolConstants.heartbeatAckPayloadBytes else { return nil }
        return HeartbeatAck(
            backendAvailable: payload.byte(0) != 0,
            activeCount: payload.byte(1),
            epoch: payload.u16BE(2),
            bitmap: payload.u16BE(4)
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
        guard payload.count >= ProtocolConstants.rumblePayloadBytes else { return nil }
        return RumbleCommand(
            controllerIndex: payload.byte(0),
            strongMagnitude: payload.u16BE(1),
            weakMagnitude: payload.u16BE(3),
            durationMs: payload.u16BE(5)
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
        guard payload.count >= ProtocolConstants.lightbarPayloadBytes else { return nil }
        return LightbarCommand(controllerIndex: payload.byte(0), r: payload.byte(1), g: payload.byte(2), b: payload.byte(3))
    }
}
