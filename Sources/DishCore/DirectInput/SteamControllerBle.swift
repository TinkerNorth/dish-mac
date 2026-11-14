// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// The 2015 Steam Controller over Bluetooth LE (28de:1106), read as SDL reads
// it on macOS, through IOHIDManager (`SDL_hidapi_steam.c`): input report 3
// carries one segment of a packet, a header (data, last, the segment's
// number) and 18 bytes, and the segments assemble into a packet whose low
// nibble is its type and whose option mask names the chunks that follow, in
// `UpdateBLESteamControllerState`'s order. A packet carries only some chunks;
// the rest keep what they last said, and all of it reads through the wired
// pad's mappings. Each feature report goes out on report 3 as one segment,
// as SDL's `SetFeatureReport` frames one that fits. Decoding reads the
// caller's buffer in place into a packet buffer the carry made once, so a
// report builds nothing.

import Foundation

enum SteamBleLayout {
    static let reportId: UInt8 = 0x03
    static let segmentLength = 20
    static let headerByte = 1
    static let payloadOffset = 2
    static let payloadLength = 18
    /// A segment's number is three bits.
    static let maxSegments = 8
    static let dataFlag: UInt8 = 0x80
    static let lastFlag: UInt8 = 0x40
    static let numberMask: UInt8 = 0x07
    static let typeMask: UInt8 = 0x0F
    static let stateType: UInt8 = 4
    /// The option mask's low byte rides the type byte's high nibble.
    static let maskInTypeByte: UInt8 = 0xF0
    static let maskByte = 1
    static let firstChunk = 2
}

/// SDL's `EBLEOptionDataChunksBitmask`, in the order a packet carries them.
enum SteamBleChunkKind {
    case buttons
    case triggers
    /// The button word's top bytes, which no mapping reads.
    case highButtons
    case stick
    case leftPad
    case rightPad
    case accel
    case gyro
    /// The orientation, which SDL keeps and never reads.
    case quaternion
}

struct SteamBleChunk {
    let kind: SteamBleChunkKind
    let mask: UInt32
    let length: Int
}

let steamBleChunks = [
    SteamBleChunk(kind: .buttons, mask: 0x0010, length: 3),
    SteamBleChunk(kind: .triggers, mask: 0x0020, length: 2),
    SteamBleChunk(kind: .highButtons, mask: 0x0040, length: 3),
    SteamBleChunk(kind: .stick, mask: 0x0080, length: 4),
    SteamBleChunk(kind: .leftPad, mask: 0x0100, length: 4),
    SteamBleChunk(kind: .rightPad, mask: 0x0200, length: 4),
    SteamBleChunk(kind: .accel, mask: 0x0400, length: 6),
    SteamBleChunk(kind: .gyro, mask: 0x0800, length: 6),
    SteamBleChunk(kind: .quaternion, mask: 0x1000, length: 8)
]

/// SDL's `SteamControllerPacketAssembler` on its BLE path: the segments of
/// one packet, in order from its first.
struct SteamBleAssembly: Equatable {
    private var packet = [UInt8](repeating: 0, count: SteamBleLayout.payloadLength * SteamBleLayout.maxSegments)
    private var nextSegment: UInt8 = 0

    /// SDL's `WriteSegmentToSteamControllerPacketAssembler`: the packet's
    /// length once its last segment is in; nil before then and for a report
    /// it drops.
    mutating func add(_ report: UnsafeBufferPointer<UInt8>) -> Int? {
        guard report.first == SteamBleLayout.reportId else { return nil }
        guard report.count == SteamBleLayout.segmentLength else {
            nextSegment = 0
            return nil
        }
        let header = report[SteamBleLayout.headerByte]
        guard header & SteamBleLayout.dataFlag != 0 else { return nil }
        let number = header & SteamBleLayout.numberMask
        guard takes(number) else { return nil }
        write(report, segment: number)
        let last = header & SteamBleLayout.lastFlag != 0
        guard last else {
            nextSegment = number + 1
            return nil
        }
        nextSegment = 0
        return (Int(number) + 1) * SteamBleLayout.payloadLength
    }

    /// The packet's first `length` bytes, read in place.
    func reading<Result>(_ length: Int, _ body: (UnsafeBufferPointer<UInt8>) -> Result) -> Result {
        packet.withUnsafeBufferPointer { body(UnsafeBufferPointer(rebasing: $0.prefix(length))) }
    }

    /// The segment SDL expects is kept; any other starts the packet over,
    /// and is kept only when it is a packet's first.
    private mutating func takes(_ number: UInt8) -> Bool {
        guard number != nextSegment else { return true }
        nextSegment = 0
        return number == 0
    }

    private mutating func write(_ report: UnsafeBufferPointer<UInt8>, segment number: UInt8) {
        let start = Int(number) * SteamBleLayout.payloadLength
        for index in 0 ..< SteamBleLayout.payloadLength {
            packet[start + index] = report[SteamBleLayout.payloadOffset + index]
        }
    }
}

/// What the state packets' chunks have said so far, as the pad sent it.
struct SteamBleHeld: Equatable {
    var buttons: UInt32 = 0
    var leftTrigger: UInt8 = 0
    var rightTrigger: UInt8 = 0
    var stick = SteamAxisPair.zero
    var leftPad = SteamAxisPair.zero
    var rightPad = SteamAxisPair.zero
    var accel = SteamAxisTriple.zero
    var gyro = SteamAxisTriple.zero
}

/// The pad's decode state that spans reports: the packet being assembled
/// and what the chunks have said so far.
public struct SteamBleCarry: Equatable, Sendable {
    var assembly = SteamBleAssembly()
    var held = SteamBleHeld()

    public init() {}
}

/// Nil for a report that completes no state packet: the pad's keyboard and
/// mouse, a segment of a packet still coming, a packet of another type, and
/// one that names more chunks than it carries, which leaves what was held.
public func decodeSteamControllerBle(_ report: UnsafeBufferPointer<UInt8>, carry: inout SteamBleCarry) -> SteamReading? {
    guard let length = carry.assembly.add(report) else { return nil }
    let held = carry.held
    let next = carry.assembly.reading(length) { steamBleState($0, over: held) }
    guard let next else { return nil }
    carry.held = next
    return steamBleReading(next)
}

private func steamBleState(_ packet: UnsafeBufferPointer<UInt8>, over held: SteamBleHeld) -> SteamBleHeld? {
    let isState = packet[0] & SteamBleLayout.typeMask == SteamBleLayout.stateType
    guard isState else { return nil }
    return readSteamBleChunks(packet, over: held)
}

private func readSteamBleChunks(_ packet: UnsafeBufferPointer<UInt8>, over held: SteamBleHeld) -> SteamBleHeld? {
    let maskLow = UInt32(packet[0] & SteamBleLayout.maskInTypeByte)
    let maskHigh = UInt32(packet[SteamBleLayout.maskByte]) << 8
    let mask = maskLow | maskHigh
    var next = held
    var offset = SteamBleLayout.firstChunk
    for chunk in steamBleChunks where mask & chunk.mask != 0 {
        guard offset + chunk.length <= packet.count else { return nil }
        readSteamBleChunk(chunk.kind, packet, at: offset, into: &next)
        offset += chunk.length
    }
    return next
}

private func readSteamBleChunk(
    _ kind: SteamBleChunkKind,
    _ packet: UnsafeBufferPointer<UInt8>,
    at offset: Int,
    into held: inout SteamBleHeld
) {
    switch kind {
    case .buttons:
        held.buttons = steamLe24(packet, offset)
    case .triggers:
        held.leftTrigger = packet[offset]
        held.rightTrigger = packet[offset + 1]
    case .stick:
        held.stick = steamAxisPair(packet, at: offset)
    case .leftPad:
        held.leftPad = steamAxisPair(packet, at: offset)
    case .rightPad:
        held.rightPad = steamAxisPair(packet, at: offset)
    case .accel:
        held.accel = steamAxisTriple(packet, at: offset)
    case .gyro:
        held.gyro = steamAxisTriple(packet, at: offset)
    case .highButtons, .quaternion:
        break
    }
}

/// Through the wired pad's mappings; the stick has a chunk of its own here,
/// so none of the wired pad's shared-axes rules apply.
private func steamBleReading(_ held: SteamBleHeld) -> SteamReading {
    var buttons = steamButtons(held.buttons, steamControllerButtonBits)
    if held.buttons & SteamButtonMask.stickButton != 0 { buttons.insert(.leftThumb) }
    let report = GamepadReport(
        buttons: buttons.rawValue,
        lt: steamTrigger(held.leftTrigger),
        rt: steamTrigger(held.rightTrigger),
        lx: held.stick.x,
        ly: held.stick.y,
        extButtons: steamExtendedButtons(held.buttons, steamControllerExtendedBits)
    )
    let pads = steamPads(left: held.leftPad, right: held.rightPad, held: held.buttons)
    return .state(report, motion: steamMotion(accel: held.accel, gyro: held.gyro), pads: pads)
}

// MARK: - Feature reports

/// SDL's `ResetSteamController` settings: wireless packet version 2, both
/// trackpads off, no smoothed mouse.
private let resetSettings: [UInt8] = [0x87, 0x0C, 0x31, 0x02, 0x00, 0x07, 0x07, 0x00, 0x08, 0x07, 0x00, 0x18, 0x00, 0x00]
/// `SetSensorsEnabled`: raw accel and raw gyro.
private let rawImu: [UInt8] = [0x87, 0x03, 0x30, 0x18, 0x00]

/// The quiet sequence is SDL's `ResetSteamController` and `SetSensorsEnabled`,
/// less its attributes query, whose one answer is a sensor rate Dish does not
/// use; the restore is the wired pad's, as SDL's `CloseSteamController` sends
/// it on either link.
public func steamBleConfigReports(_ stage: SteamConfigStage) -> [[UInt8]] {
    steamBleConfigMessages(stage).map(steamBleFeatureReport)
}

private func steamBleConfigMessages(_ stage: SteamConfigStage) -> [[UInt8]] {
    switch stage {
    case .quiet: [clearDigitalMappings, loadDefaultSettings, resetSettings, rawImu]
    case .restore: steamConfigMessages(.restore)
    }
}

/// The message as its packet's one segment: report 3, the header of a first
/// and last data segment, the message, zeros to the segment's end.
private func steamBleFeatureReport(_ message: [UInt8]) -> [UInt8] {
    let framed = [SteamBleLayout.reportId, SteamBleLayout.dataFlag | SteamBleLayout.lastFlag] + message
    return framed + [UInt8](repeating: 0, count: SteamBleLayout.segmentLength - framed.count)
}
