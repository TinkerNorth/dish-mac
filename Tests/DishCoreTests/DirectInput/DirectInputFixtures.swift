// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// Byte fixtures for the Direct decoders. The Switch builders mirror
// dish-android's `usb_parsers_test.cpp`; the descriptors are the desktops'
// `test_usb_hid_layout.cpp` and `test_usb_hid_layout_orders.cpp` bytes.

import DishCore

/// A Switch 0x30 report under construction, zeroed past the id.
struct SwitchReportBytes {
    static let center: UInt16 = 2048
    static let deadzone: UInt16 = 320
    static let rawMax: UInt16 = 4095

    var bytes: [UInt8]

    init(length: Int = 12) {
        bytes = [UInt8](repeating: 0, count: length)
        bytes[0] = 0x30
    }

    init(raw: [UInt8]) {
        bytes = raw
    }

    /// Two axes per three bytes, as report 0x30 lays them out.
    mutating func setSticks(lx: UInt16, ly: UInt16, rx: UInt16 = center, ry: UInt16 = center) {
        bytes[6] = UInt8(lx & 0xFF)
        bytes[7] = UInt8(((lx >> 8) & 0x0F) | ((ly & 0x0F) << 4))
        bytes[8] = UInt8(ly >> 4)
        bytes[9] = UInt8(rx & 0xFF)
        bytes[10] = UInt8(((rx >> 8) & 0x0F) | ((ry & 0x0F) << 4))
        bytes[11] = UInt8(ry >> 4)
    }

    mutating func setLe16(_ offset: Int, _ value: Int16) {
        let word = UInt16(bitPattern: value)
        bytes[offset] = UInt8(word & 0xFF)
        bytes[offset + 1] = UInt8(word >> 8)
    }

    func decode(_ kind: SwitchPadKind, calibration: inout SwitchStickCalibration) -> SwitchReading? {
        bytes.withUnsafeBufferPointer { decodeSwitchReport($0, kind: kind, calibration: &calibration) }
    }

    /// Decoded against a fresh calibration, as Android's `decodeFresh`.
    func decodeFresh(_ kind: SwitchPadKind) -> SwitchReading? {
        var calibration = SwitchStickCalibration()
        return decode(kind, calibration: &calibration)
    }
}

/// One bit of one byte and the wire button it should press alone.
struct BitCase {
    let mask: UInt8
    let expected: WireButtonWord
}

func decodeHid(_ layout: HidGamepadLayout, _ bytes: [UInt8]) -> GamepadReport? {
    bytes.withUnsafeBufferPointer { layout.decode($0) }
}

enum HidDescriptors {
    /// X/Y/Z/Rz bytes 0-3, a 4-bit hat and 4-bit pad, 10 buttons and 6-bit pad: 7 bytes, no id.
    static let gamepad: [UInt8] = [
        0x05, 0x01, 0x09, 0x05, 0xA1, 0x01, 0x05, 0x01, 0x09, 0x30, 0x09, 0x31, 0x09, 0x32, 0x09, 0x35,
        0x15, 0x00, 0x26, 0xFF, 0x00, 0x75, 0x08, 0x95, 0x04, 0x81, 0x02, 0x09, 0x39, 0x15, 0x00, 0x25,
        0x07, 0x75, 0x04, 0x95, 0x01, 0x81, 0x42, 0x75, 0x04, 0x95, 0x01, 0x81, 0x01, 0x05, 0x09, 0x19,
        0x01, 0x29, 0x0A, 0x15, 0x00, 0x25, 0x01, 0x75, 0x01, 0x95, 0x0A, 0x81, 0x02, 0x75, 0x01, 0x95,
        0x06, 0x81, 0x01, 0xC0
    ]

    /// X/Y behind report id 3: the report is {0x03, X, Y}.
    static let reportId: [UInt8] = [
        0x05, 0x01, 0x09, 0x05, 0xA1, 0x01, 0x85, 0x03, 0x09, 0x30, 0x09, 0x31, 0x15, 0x00, 0x26, 0xFF,
        0x00, 0x75, 0x08, 0x95, 0x02, 0x81, 0x02, 0xC0
    ]

    /// One 32-bit X axis with a 31-bit logical maximum.
    static let wideAxis: [UInt8] = [
        0x05, 0x01, 0x09, 0x05, 0xA1, 0x01, 0x09, 0x30, 0x15, 0x00, 0x27, 0xFF, 0xFF, 0xFF, 0x7F, 0x75,
        0x20, 0x95, 0x01, 0x81, 0x02, 0xC0
    ]

    /// A 4-direction hat (logical 0...3); raw 4 is the out-of-range null.
    static let narrowHat: [UInt8] = [
        0x05, 0x01, 0x09, 0x05, 0xA1, 0x01, 0x09, 0x39, 0x15, 0x00, 0x25, 0x03, 0x75, 0x08, 0x95, 0x01,
        0x81, 0x02, 0xC0
    ]

    /// PDP Faceoff Wired Pro (0e6f:0180): 14 buttons in Switch usage order and a
    /// 2-bit pad, a 4-bit hat and pad, then X/Y/Z/Rz bytes: 7 bytes, no id.
    static let switchOrder: [UInt8] = [
        0x05, 0x01, 0x09, 0x05, 0xA1, 0x01, 0x15, 0x00, 0x25, 0x01, 0x75, 0x01, 0x95, 0x0E, 0x05, 0x09,
        0x19, 0x01, 0x29, 0x0E, 0x81, 0x02, 0x95, 0x02, 0x81, 0x01, 0x05, 0x01, 0x25, 0x07, 0x75, 0x04,
        0x95, 0x01, 0x09, 0x39, 0x81, 0x42, 0x95, 0x01, 0x81, 0x01, 0x26, 0xFF, 0x00, 0x09, 0x30, 0x09,
        0x31, 0x09, 0x32, 0x09, 0x35, 0x75, 0x08, 0x95, 0x04, 0x81, 0x02, 0xC0
    ]

    /// 8BitDo M30, USB D-input, 2dc8:5006, as fwupd's m30.txt lists it: 15
    /// buttons, a hat, X/Y/Z/Rz, Accelerator and Brake, 9 bytes, no id.
    static let m30: [UInt8] = [
        0x05, 0x01, 0x09, 0x05, 0xA1, 0x01, 0x15, 0x00, 0x25, 0x01, 0x35, 0x00, 0x45, 0x01, 0x75, 0x01,
        0x95, 0x0F, 0x05, 0x09, 0x19, 0x01, 0x29, 0x0F, 0x81, 0x02, 0x95, 0x01, 0x81, 0x01, 0x05, 0x01,
        0x25, 0x07, 0x46, 0x3B, 0x01, 0x75, 0x04, 0x95, 0x01, 0x65, 0x14, 0x09, 0x39, 0x81, 0x42, 0x65,
        0x00, 0x95, 0x01, 0x81, 0x01, 0x26, 0xFF, 0x00, 0x46, 0xFF, 0x00, 0x09, 0x30, 0x09, 0x31, 0x09,
        0x32, 0x09, 0x35, 0x75, 0x08, 0x95, 0x04, 0x81, 0x02, 0x05, 0x02, 0x15, 0x00, 0x26, 0xFF, 0x00,
        0x09, 0xC4, 0x09, 0xC5, 0x95, 0x02, 0x75, 0x08, 0x81, 0x02, 0x05, 0x08, 0x09, 0x43, 0x15, 0x00,
        0x26, 0xFF, 0x00, 0x35, 0x00, 0x46, 0xFF, 0x00, 0x75, 0x08, 0x95, 0x02, 0x91, 0x82, 0x09, 0x44,
        0x91, 0x82, 0x09, 0x45, 0x91, 0x82, 0x09, 0x46, 0x91, 0x82, 0xC0
    ]

    /// 8BitDo USB Wireless Adapter 2, D-input, 2dc8:3105, from sys-con issue 65:
    /// the M30's layout behind report id 1, a vendor input report 2 and an output 0x81.
    static let adapter2: [UInt8] = [
        0x05, 0x01, 0x09, 0x05, 0xA1, 0x01, 0x85, 0x01, 0x15, 0x00, 0x25, 0x01, 0x35, 0x00, 0x45,
        0x01, 0x75, 0x01, 0x95, 0x0F, 0x05, 0x09, 0x19, 0x01, 0x29, 0x0F, 0x81, 0x02, 0x95, 0x01,
        0x81, 0x01, 0x05, 0x01, 0x25, 0x07, 0x46, 0x3B, 0x01, 0x75, 0x04, 0x95, 0x01, 0x65, 0x14,
        0x09, 0x39, 0x81, 0x42, 0x65, 0x00, 0x95, 0x01, 0x81, 0x01, 0x26, 0xFF, 0x00, 0x46, 0xFF,
        0x00, 0x09, 0x30, 0x09, 0x31, 0x09, 0x32, 0x09, 0x35, 0x75, 0x08, 0x95, 0x04, 0x81, 0x02,
        0x05, 0x02, 0x15, 0x00, 0x26, 0xFF, 0x00, 0x09, 0xC4, 0x09, 0xC5, 0x95, 0x02, 0x75, 0x08,
        0x81, 0x02, 0x05, 0x08, 0x09, 0x43, 0x15, 0x00, 0x26, 0xFF, 0x00, 0x35, 0x00, 0x46, 0xFF,
        0x00, 0x75, 0x08, 0x95, 0x02, 0x91, 0x82, 0x09, 0x44, 0x91, 0x82, 0x09, 0x45, 0x91, 0x82,
        0x09, 0x46, 0x91, 0x82, 0x85, 0x02, 0x09, 0x02, 0x75, 0x08, 0x95, 0x3F, 0x81, 0x03, 0x85,
        0x81, 0x09, 0x03, 0x75, 0x08, 0x95, 0x3F, 0x91, 0x83, 0xC0
    ]

    /// PlayStation Classic controller, 054c:0cda, from TitanTwo issue 177: ten
    /// buttons, then X and Y as 2-bit three-state directions, 2 bytes, no id.
    static let psClassic: [UInt8] = [
        0x05, 0x01, 0x09, 0x05, 0xA1, 0x01, 0x15, 0x00, 0x25, 0x01, 0x75, 0x01, 0x95,
        0x0A, 0x05, 0x09, 0x19, 0x01, 0x29, 0x0A, 0x81, 0x02, 0x05, 0x01, 0x09, 0x30,
        0x09, 0x31, 0x15, 0x00, 0x25, 0x02, 0x35, 0x00, 0x45, 0x02, 0x75, 0x02, 0x95,
        0x02, 0x81, 0x02, 0x75, 0x01, 0x95, 0x02, 0x81, 0x01, 0xC0
    ]

    /// X/Y 8-bit over 0...0xFF written as a one-byte maximum, two buttons, a pad.
    static let oneByteMaximum: [UInt8] = [
        0x05, 0x01, 0x09, 0x05, 0xA1, 0x01, 0x09, 0x30, 0x09, 0x31, 0x15, 0x00, 0x25, 0xFF, 0x75,
        0x08, 0x95, 0x02, 0x81, 0x02, 0x05, 0x09, 0x19, 0x01, 0x29, 0x02, 0x15, 0x00, 0x25, 0x01,
        0x75, 0x01, 0x95, 0x02, 0x81, 0x02, 0x75, 0x06, 0x95, 0x01, 0x81, 0x01, 0xC0
    ]

    /// The same over -127...127.
    static let signedOneByte: [UInt8] = [
        0x05, 0x01, 0x09, 0x05, 0xA1, 0x01, 0x09, 0x30, 0x09, 0x31, 0x15, 0x81, 0x25, 0x7F, 0x75,
        0x08, 0x95, 0x02, 0x81, 0x02, 0x05, 0x09, 0x19, 0x01, 0x29, 0x02, 0x15, 0x00, 0x25, 0x01,
        0x75, 0x01, 0x95, 0x02, 0x81, 0x02, 0x75, 0x06, 0x95, 0x01, 0x81, 0x01, 0xC0
    ]

    /// X/Y as full-range signed 32-bit, then eight buttons.
    static let signed32Axes: [UInt8] = [
        0x05, 0x01, 0x09, 0x05, 0xA1, 0x01, 0x09, 0x30, 0x09, 0x31, 0x17, 0x00, 0x00, 0x00, 0x80,
        0x27, 0xFF, 0xFF, 0xFF, 0x7F, 0x75, 0x20, 0x95, 0x02, 0x81, 0x02, 0x05, 0x09, 0x19, 0x01,
        0x29, 0x08, 0x15, 0x00, 0x25, 0x01, 0x75, 0x01, 0x95, 0x08, 0x81, 0x02, 0xC0
    ]

    /// Rx/Ry (the triggers) as full-range signed 32-bit, then eight buttons.
    static let signed32Triggers: [UInt8] = [
        0x05, 0x01, 0x09, 0x05, 0xA1, 0x01, 0x09, 0x33, 0x09, 0x34, 0x17, 0x00, 0x00, 0x00, 0x80,
        0x27, 0xFF, 0xFF, 0xFF, 0x7F, 0x75, 0x20, 0x95, 0x02, 0x81, 0x02, 0x05, 0x09, 0x19, 0x01,
        0x29, 0x08, 0x15, 0x00, 0x25, 0x01, 0x75, 0x01, 0x95, 0x08, 0x81, 0x02, 0xC0
    ]
}

/// A 2015 Steam Controller packet under construction: 64 bytes framed
/// {version 0x0001 LE, type, payload length}, as the desktops' `steamState`
/// and `steamWirelessEvent` build it (dish-android's vectors, verified on a
/// wired 28de:1102).
struct SteamPacketBytes {
    var bytes = [UInt8](repeating: 0, count: 64)

    /// A state packet with the 24-bit button word at bytes 8...10.
    static func state(_ buttons: UInt32 = 0) -> SteamPacketBytes {
        var packet = SteamPacketBytes()
        packet.bytes[0] = 0x01
        packet.bytes[2] = 0x01
        packet.bytes[3] = 44
        packet.bytes[8] = UInt8(buttons & 0xFF)
        packet.bytes[9] = UInt8((buttons >> 8) & 0xFF)
        packet.bytes[10] = UInt8((buttons >> 16) & 0xFF)
        return packet
    }

    /// A receiver's wireless event: payload 0x01 disconnected, 0x02 connected.
    static func wireless(_ payload: UInt8) -> SteamPacketBytes {
        var packet = SteamPacketBytes()
        packet.bytes[0] = 0x01
        packet.bytes[2] = 0x03
        packet.bytes[3] = 0x01
        packet.bytes[4] = payload
        return packet
    }

    mutating func setLe16(_ offset: Int, _ value: Int16) {
        let word = UInt16(bitPattern: value)
        bytes[offset] = UInt8(word & 0xFF)
        bytes[offset + 1] = UInt8(word >> 8)
    }

    func decode(hold: inout SteamStickHold) -> SteamReading? {
        bytes.withUnsafeBufferPointer { decodeSteamControllerPacket($0, hold: &hold) }
    }

    func decodeFresh() -> SteamReading? {
        var hold = SteamStickHold()
        return decode(hold: &hold)
    }
}

/// A 2015 Steam Controller state packet over Bluetooth LE under construction,
/// from SDL's `UpdateBLESteamControllerState`: the type (4, a state) in the
/// first byte's low nibble, the option mask's low byte in its high nibble and
/// the mask's next byte after it, then each chunk the mask names, in the
/// mask's bit order. `reports` cuts it into the input reports macOS delivers:
/// report 3, the segment's header (0x80 data, 0x40 its packet's last, its
/// number), 18 bytes.
struct SteamBlePacketBytes {
    static let buttons: UInt32 = 0x0010
    static let triggers: UInt32 = 0x0020
    static let highButtons: UInt32 = 0x0040
    static let stick: UInt32 = 0x0080
    static let leftPad: UInt32 = 0x0100
    static let rightPad: UInt32 = 0x0200
    static let accel: UInt32 = 0x0400
    static let gyro: UInt32 = 0x0800
    static let quaternion: UInt32 = 0x1000
    static let payloadLength = 18

    var type: UInt8 = 4
    private var chunks: [UInt32: [UInt8]] = [:]

    func with(_ chunk: UInt32, _ bytes: [UInt8]) -> SteamBlePacketBytes {
        var packet = self
        packet.chunks[chunk] = bytes
        return packet
    }

    /// The low three bytes of the button word.
    func buttons(_ word: UInt32) -> SteamBlePacketBytes {
        with(Self.buttons, [UInt8(word & 0xFF), UInt8((word >> 8) & 0xFF), UInt8((word >> 16) & 0xFF)])
    }

    func triggers(left: UInt8, right: UInt8) -> SteamBlePacketBytes {
        with(Self.triggers, [left, right])
    }

    func stick(x: Int16, y: Int16) -> SteamBlePacketBytes {
        with(Self.stick, le16(x) + le16(y))
    }

    func leftPad(x: Int16, y: Int16) -> SteamBlePacketBytes {
        with(Self.leftPad, le16(x) + le16(y))
    }

    func rightPad(x: Int16, y: Int16) -> SteamBlePacketBytes {
        with(Self.rightPad, le16(x) + le16(y))
    }

    func accel(_ x: Int16, _ y: Int16, _ z: Int16) -> SteamBlePacketBytes {
        with(Self.accel, le16(x) + le16(y) + le16(z))
    }

    func gyro(_ x: Int16, _ y: Int16, _ z: Int16) -> SteamBlePacketBytes {
        with(Self.gyro, le16(x) + le16(y) + le16(z))
    }

    var packet: [UInt8] {
        let mask = chunks.keys.reduce(0, |)
        let body = chunks.keys.sorted().flatMap { chunks[$0] ?? [] }
        return [UInt8(mask & 0xF0) | type, UInt8(mask >> 8)] + body
    }

    /// The packet as consecutive segments, the last flagged.
    var reports: [[UInt8]] {
        let bytes = packet
        let count = (bytes.count + Self.payloadLength - 1) / Self.payloadLength
        return (0 ..< count).map { Self.segment(number: $0, last: $0 == count - 1, payloadOf(bytes, segment: $0)) }
    }

    /// One input report: report 3, the header, the payload padded to 18 bytes.
    static func segment(number: Int, last: Bool, _ payload: [UInt8], carriesData: Bool = true) -> [UInt8] {
        let data: UInt8 = carriesData ? 0x80 : 0
        let lastFlag: UInt8 = last ? 0x40 : 0
        let header = data | lastFlag | UInt8(number)
        return [0x03, header] + payload + [UInt8](repeating: 0, count: payloadLength - payload.count)
    }

    /// Every report through the decoder in turn: the reading the last brings.
    func decode(carry: inout SteamBleCarry) -> SteamReading? {
        var reading: SteamReading?
        for report in reports {
            reading = decodeBleReport(report, carry: &carry)
        }
        return reading
    }
}

private func le16(_ value: Int16) -> [UInt8] {
    let word = UInt16(bitPattern: value)
    return [UInt8(word & 0xFF), UInt8(word >> 8)]
}

private func payloadOf(_ packet: [UInt8], segment: Int) -> [UInt8] {
    Array(packet.dropFirst(segment * SteamBlePacketBytes.payloadLength).prefix(SteamBlePacketBytes.payloadLength))
}

func decodeBleReport(_ report: [UInt8], carry: inout SteamBleCarry) -> SteamReading? {
    report.withUnsafeBufferPointer { decodeSteamControllerBle($0, carry: &carry) }
}

/// A 2026 Steam Controller input report under construction: the report id,
/// then SDL's `TritonMTUNoQuat_t` (46 bytes in all) or the battery and
/// wireless payloads.
struct TritonReportBytes {
    var bytes: [UInt8]

    /// A state report with the 32-bit button word at bytes 2...5 and the
    /// IMU tick where the report's shape keeps it.
    static func state(_ buttons: UInt32 = 0, reportId: UInt8 = 0x42, length: Int = 46, imuTick: UInt32 = 0) -> TritonReportBytes {
        var report = TritonReportBytes(bytes: [UInt8](repeating: 0, count: length))
        report.bytes[0] = reportId
        report.bytes[2] = UInt8(buttons & 0xFF)
        report.bytes[3] = UInt8((buttons >> 8) & 0xFF)
        report.bytes[4] = UInt8((buttons >> 16) & 0xFF)
        report.bytes[5] = UInt8((buttons >> 24) & 0xFF)
        report.setImuTick(imuTick)
        return report
    }

    /// Four bytes at 30 (`TritonMTUIMUNoQuat_t`), or two at 32 on the
    /// timestamped report 0x47 (`TritonMTUIMUNoQuat32usTS_t`).
    mutating func setImuTick(_ tick: UInt32) {
        if bytes[0] == 0x47 {
            setLe16(32, Int16(truncatingIfNeeded: tick))
        } else {
            setLe32(30, tick)
        }
    }

    /// `TritonBatteryStatus_t`: the charge state, then the percent.
    static func battery(chargeState: UInt8, level: UInt8) -> TritonReportBytes {
        var report = TritonReportBytes(bytes: [UInt8](repeating: 0, count: 15))
        report.bytes[0] = 0x43
        report.bytes[1] = chargeState
        report.bytes[2] = level
        return report
    }

    /// A wireless status: 1 disconnected, 2 connected.
    static func wireless(_ state: UInt8, reportId: UInt8 = 0x79) -> TritonReportBytes {
        TritonReportBytes(bytes: [reportId, state])
    }

    mutating func setLe16(_ offset: Int, _ value: Int16) {
        let word = UInt16(bitPattern: value)
        bytes[offset] = UInt8(word & 0xFF)
        bytes[offset + 1] = UInt8(word >> 8)
    }

    mutating func setLe32(_ offset: Int, _ value: UInt32) {
        bytes[offset] = UInt8(value & 0xFF)
        bytes[offset + 1] = UInt8((value >> 8) & 0xFF)
        bytes[offset + 2] = UInt8((value >> 16) & 0xFF)
        bytes[offset + 3] = UInt8((value >> 24) & 0xFF)
    }

    func decode(carry: inout TritonCarry) -> SteamReading? {
        bytes.withUnsafeBufferPointer { decodeTritonReport($0, carry: &carry) }
    }

    /// Decoded as a pad's first report, against a fresh carry.
    func decode() -> SteamReading? {
        var carry = TritonCarry()
        return decode(carry: &carry)
    }
}

/// A Switch Pro Controller (057e:2009) on USB as it answered a Mac running
/// macOS 27, every report 64 bytes: silent as plugged in, it acknowledges
/// each handshake and the switch to 3 Mbit, and streams its full reports
/// from the timeout disable that follows a handshake at 3 Mbit. The
/// handshake, timeout disable and report mode alone, a handshake sent
/// twice, and the 3 Mbit switch without the handshake after it each left
/// it silent. Its IMU words read zero, at rest on a desk, until subcommand
/// 0x40 turns the IMU on.
struct CapturedSwitchPro {
    static let handshakeReply = paddedToOneUsbPacket([0x81, 0x02])
    static let highSpeedReply = paddedToOneUsbPacket([0x81, 0x03])
    /// The 0x21 reply to subcommand 0x03: the input state, then ack 0x80 for 0x03.
    static let subcommandReply = paddedToOneUsbPacket([
        0x21, 0xDC, 0x81, 0x00, 0x80, 0x00, 0x18, 0xB7, 0x7F, 0x4A, 0xE8, 0x82, 0x00, 0x80, 0x03
    ])
    /// At rest on its cable, the IMU frames all zero.
    static let idleFullReport = paddedToOneUsbPacket([0x30, 0xA7, 0x81, 0x00, 0x80, 0x00, 0x19, 0xB7, 0x7F, 0x4B, 0xF8, 0x82])
    static let fullReportModeSubcommand: [UInt8] = [0x01, 0x00, 0x00, 0x01, 0x40, 0x40, 0x00, 0x01, 0x40, 0x40, 0x03, 0x30]
    static let enableImuSubcommand: [UInt8] = [0x01, 0x01, 0x00, 0x01, 0x40, 0x40, 0x00, 0x01, 0x40, 0x40, 0x40, 0x01]

    private static let handshakeAtThreeMegabit: [[UInt8]] = [[0x80, 0x02], [0x80, 0x03], [0x80, 0x02]]
    private static let timeoutDisable: [UInt8] = [0x80, 0x04]
    private static let subcommandReport: UInt8 = 0x01
    private static let subcommandByte = 10
    private static let enableImu: [UInt8] = [0x40, 0x01]

    /// Each packet's command: its first two bytes.
    private(set) var received: [[UInt8]] = []
    private(set) var streams = false
    private(set) var imuOn = false

    mutating func receive(_ packet: [UInt8]) {
        let command = Array(packet.prefix(2))
        let lastThree = Array(received.suffix(Self.handshakeAtThreeMegabit.count))
        let disablesTheTimeoutAtThreeMegabit = command == Self.timeoutDisable && lastThree == Self.handshakeAtThreeMegabit
        if disablesTheTimeoutAtThreeMegabit { streams = true }
        if Self.enablesTheImu(packet) { imuOn = true }
        received.append(command)
    }

    private static func enablesTheImu(_ packet: [UInt8]) -> Bool {
        let subcommand = Array(packet.dropFirst(subcommandByte).prefix(enableImu.count))
        return packet[0] == subcommandReport && subcommand == enableImu
    }
}

private func paddedToOneUsbPacket(_ bytes: [UInt8]) -> [UInt8] {
    bytes + [UInt8](repeating: 0, count: switchStartPacketBytes - bytes.count)
}
