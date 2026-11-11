// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// The 2015 Steam Controller (28de:1102 wired, 28de:1142 wireless receiver)
// on its vendor-defined HID interface: 64-byte packets framed {version
// 0x0001 LE, type, payload length, payload}, a state packet, the receiver's
// connect and disconnect events, and the feature reports that quiet the
// pad's keyboard and mouse emulation ("lizard mode") and give them back.
// Ported byte for byte from the desktops' `UsbReportParsers.h`
// (`decodeSteamController`, `buildSteamConfigPacket`, `checkWirelessEvent`),
// which mirror dish-android's port of SDL's `SDL_hidapi_steam.c` and Linux's
// `hid-steam`, verified on a wired pad; the receiver's state request is
// SDL's (`HIDAPI_DriverSteam_InitDevice`). Decoding reads the caller's
// buffer in place and builds no collection.

import Foundation

/// A wireless receiver's slot gained or lost its controller.
public enum SteamLink: Equatable, Sendable {
    case connected
    case disconnected
}

/// One report off a Steam Controller's interface, of either generation.
public enum SteamReading: Equatable, Sendable {
    /// The pad on the XUSB layout, and its IMU when the block carries one.
    case state(GamepadReport, motion: MotionSample?)
    /// The pad's own charge: the 2026 pad's battery report.
    case battery(PadBattery)
    case link(SteamLink)
}

/// The left stick's last value, held across the frames whose shared left
/// axes carry the left pad instead.
public struct SteamStickHold: Equatable, Sendable {
    public var x: Int16 = 0
    public var y: Int16 = 0

    public init() {}
}

/// What one state packet's left axes carry.
public enum SteamLeftAxes: Equatable, Sendable {
    /// The stick: its value is read and held.
    case stick
    /// The pad alone: the stick is idle, so it centres.
    case pad
    /// The pad, interleaved with stick frames: the held value stands.
    case padBesideStick
}

enum SteamPacketLayout {
    static let stateLength = 48
    static let linkLength = 5
    static let versionLow: UInt8 = 0x01
    static let versionHigh: UInt8 = 0x00
    static let typeByte = 2
    static let payloadLengthByte = 3
    static let linkEventByte = 4
    static let stateType: UInt8 = 0x01
    static let linkType: UInt8 = 0x03
    static let linkPayloadLength: UInt8 = 0x01
    static let disconnected: UInt8 = 0x01
    static let connected: UInt8 = 0x02
    static let buttons = 8
    static let leftTrigger = 11
    static let rightTrigger = 12
    static let leftAxes = 16
    static let rightPad = 20
    static let accel = 28
    static let gyro = 34
}

enum SteamScale {
    /// Valve's trigger full scale, so the throw saturates before the raw rail.
    static let triggerFullScale: Int32 = 26000
    static let triggerWidenShift: Int32 = 7
    static let triggerMax: Int32 = 255
    /// 15 degrees in Q16: the pads sit rotated on the shell, as SDL corrects.
    static let padCos: Int64 = 63303
    static let padSin: Int64 = 16962
    static let q16: Int64 = 65536
    /// Gyro over ±2000 deg/s and accel over ±2 g on ±32768, against the
    /// wire's ±2000 deg/s and ±4 g on ±32767.
    static let gyroDivisor: Int64 = 32768
    static let accelDivisor: Int64 = 65536
    static let wireMax: Int64 = 32767
}

enum SteamButtonMask {
    static let rightBumper: UInt32 = 0x000004
    static let leftBumper: UInt32 = 0x000008
    static let north: UInt32 = 0x000010
    static let east: UInt32 = 0x000020
    static let west: UInt32 = 0x000040
    static let south: UInt32 = 0x000080
    static let dpadUp: UInt32 = 0x000100
    static let dpadRight: UInt32 = 0x000200
    static let dpadLeft: UInt32 = 0x000400
    static let dpadDown: UInt32 = 0x000800
    static let menu: UInt32 = 0x001000
    static let guide: UInt32 = 0x002000
    static let escape: UInt32 = 0x004000
    static let leftPadClicked: UInt32 = 0x020000
    static let rightPadClicked: UInt32 = 0x040000
    static let leftPadFinger: UInt32 = 0x080000
    static let rightPadFinger: UInt32 = 0x100000
    static let stickButton: UInt32 = 0x400000
    static let leftPadAndStick: UInt32 = 0x800000
}

/// One bit of a Steam button word and the wire button it presses.
struct SteamButtonBit {
    let mask: UInt32
    let button: WireButton
}

/// By position, as for every pad: south is XUSB A. Menu is Back and Escape
/// is Start, as SDL has them; the left thumb's two sources are decided apart.
let steamControllerButtonBits = [
    SteamButtonBit(mask: SteamButtonMask.south, button: .faceA),
    SteamButtonBit(mask: SteamButtonMask.east, button: .faceB),
    SteamButtonBit(mask: SteamButtonMask.west, button: .faceX),
    SteamButtonBit(mask: SteamButtonMask.north, button: .faceY),
    SteamButtonBit(mask: SteamButtonMask.leftBumper, button: .leftShoulder),
    SteamButtonBit(mask: SteamButtonMask.rightBumper, button: .rightShoulder),
    SteamButtonBit(mask: SteamButtonMask.menu, button: .back),
    SteamButtonBit(mask: SteamButtonMask.escape, button: .start),
    SteamButtonBit(mask: SteamButtonMask.guide, button: .guide),
    SteamButtonBit(mask: SteamButtonMask.dpadUp, button: .dpadUp),
    SteamButtonBit(mask: SteamButtonMask.dpadDown, button: .dpadDown),
    SteamButtonBit(mask: SteamButtonMask.dpadLeft, button: .dpadLeft),
    SteamButtonBit(mask: SteamButtonMask.dpadRight, button: .dpadRight),
    SteamButtonBit(mask: SteamButtonMask.rightPadClicked, button: .rightThumb)
]

func steamButtons(_ held: UInt32, _ table: [SteamButtonBit]) -> WireButtonWord {
    var word = WireButtonWord()
    for bit in table where held & bit.mask != 0 {
        word.insert(bit.button)
    }
    return word
}

func steamLe16(_ report: UnsafeBufferPointer<UInt8>, _ offset: Int) -> Int16 {
    let low = UInt16(report[offset])
    let high = UInt16(report[offset + 1]) << 8
    return Int16(bitPattern: low | high)
}

func steamGyroToWire(_ raw: Int32) -> Int16 {
    Int16(clamping: Int64(raw) * SteamScale.wireMax / SteamScale.gyroDivisor)
}

func steamAccelToWire(_ raw: Int32) -> Int16 {
    Int16(clamping: Int64(raw) * SteamScale.wireMax / SteamScale.accelDivisor)
}

/// The finger-down bit says whether the left axes carry the pad; the
/// interleave bit says stick frames come between, worth holding on to.
public func steamLeftAxes(fingerOnPad: Bool, interleaved: Bool) -> SteamLeftAxes {
    guard fingerOnPad else { return .stick }
    return interleaved ? .padBesideStick : .pad
}

/// Nil for a packet that is neither a state packet nor a receiver's event.
public func decodeSteamControllerPacket(_ packet: UnsafeBufferPointer<UInt8>, hold: inout SteamStickHold) -> SteamReading? {
    if let link = steamControllerLink(packet) { return .link(link) }
    guard isSteamStatePacket(packet) else { return nil }
    return steamControllerState(packet, hold: &hold)
}

private func hasSteamVersion(_ packet: UnsafeBufferPointer<UInt8>) -> Bool {
    packet[0] == SteamPacketLayout.versionLow && packet[1] == SteamPacketLayout.versionHigh
}

private func isSteamStatePacket(_ packet: UnsafeBufferPointer<UInt8>) -> Bool {
    guard packet.count >= SteamPacketLayout.stateLength, hasSteamVersion(packet) else { return false }
    return packet[SteamPacketLayout.typeByte] == SteamPacketLayout.stateType
}

/// The Linux driver's `ID_CONTROLLER_WIRELESS` framing: a one-byte payload.
private func steamControllerLink(_ packet: UnsafeBufferPointer<UInt8>) -> SteamLink? {
    guard packet.count >= SteamPacketLayout.linkLength, hasSteamVersion(packet) else { return nil }
    let isLinkEvent = packet[SteamPacketLayout.typeByte] == SteamPacketLayout.linkType
    let oneByte = packet[SteamPacketLayout.payloadLengthByte] == SteamPacketLayout.linkPayloadLength
    guard isLinkEvent, oneByte else { return nil }
    switch packet[SteamPacketLayout.linkEventByte] {
    case SteamPacketLayout.connected: return .connected
    case SteamPacketLayout.disconnected: return .disconnected
    default: return nil
    }
}

/// The three button bytes as one little-endian word.
private func steamButtonWord(_ packet: UnsafeBufferPointer<UInt8>) -> UInt32 {
    let low = UInt32(packet[SteamPacketLayout.buttons])
    let middle = UInt32(packet[SteamPacketLayout.buttons + 1]) << 8
    let high = UInt32(packet[SteamPacketLayout.buttons + 2]) << 16
    return low | middle | high
}

private func steamControllerState(_ packet: UnsafeBufferPointer<UInt8>, hold: inout SteamStickHold) -> SteamReading {
    let held = steamButtonWord(packet)
    let fingerOnPad = held & SteamButtonMask.leftPadFinger != 0
    let interleaved = held & SteamButtonMask.leftPadAndStick != 0
    let axes = steamLeftAxes(fingerOnPad: fingerOnPad, interleaved: interleaved)
    holdLeftStick(packet, axes, hold: &hold)
    var buttons = steamButtons(held, steamControllerButtonBits)
    if leftThumbHeld(held, axes) { buttons.insert(.leftThumb) }
    let right = steamRightStick(packet, fingerDown: held & SteamButtonMask.rightPadFinger != 0)
    let report = GamepadReport(
        buttons: buttons.rawValue,
        lt: steamTrigger(packet[SteamPacketLayout.leftTrigger]),
        rt: steamTrigger(packet[SteamPacketLayout.rightTrigger]),
        lx: hold.x,
        ly: hold.y,
        rx: right.x,
        ry: right.y
    )
    return .state(report, motion: steamControllerMotion(packet))
}

/// The stick is up-positive, as the wire is.
private func holdLeftStick(_ packet: UnsafeBufferPointer<UInt8>, _ axes: SteamLeftAxes, hold: inout SteamStickHold) {
    switch axes {
    case .stick:
        hold.x = steamLe16(packet, SteamPacketLayout.leftAxes)
        hold.y = steamLe16(packet, SteamPacketLayout.leftAxes + 2)
    case .pad:
        hold = SteamStickHold()
    case .padBesideStick:
        break
    }
}

/// The stick's own click, and the left pad's click while the firmware
/// reports a stick click as one: with no live pad and no interleaving.
private func leftThumbHeld(_ held: UInt32, _ axes: SteamLeftAxes) -> Bool {
    let stickClicked = held & SteamButtonMask.stickButton != 0
    let padClicked = held & SteamButtonMask.leftPadClicked != 0
    return stickClicked || (padClicked && axes == .stick && held & SteamButtonMask.leftPadAndStick == 0)
}

/// The right pad, rotated back square, while a finger is on it; SDL's
/// further +1000 per axis would park a stick off centre, so it is left out.
private func steamRightStick(_ packet: UnsafeBufferPointer<UInt8>, fingerDown: Bool) -> (x: Int16, y: Int16) {
    guard fingerDown else { return (0, 0) }
    let x = Int64(steamLe16(packet, SteamPacketLayout.rightPad))
    let y = Int64(steamLe16(packet, SteamPacketLayout.rightPad + 2))
    let rotatedX = (SteamScale.padCos * x - SteamScale.padSin * y) / SteamScale.q16
    let rotatedY = (SteamScale.padSin * x + SteamScale.padCos * y) / SteamScale.q16
    return (Int16(clamping: rotatedX), Int16(clamping: rotatedY))
}

/// The byte widened to Valve's 15-bit scale, saturating at its full scale.
func steamTrigger(_ raw: UInt8) -> UInt8 {
    let widened = Int32(raw) << SteamScale.triggerWidenShift | Int32(raw)
    let capped = min(widened, SteamScale.triggerFullScale)
    return UInt8(capped * SteamScale.triggerMax / SteamScale.triggerFullScale)
}

/// SDL's axes onto the wire: pitch on gyro X, yaw on gyro Z, roll on gyro
/// Y; accel X, Z and minus Y. An all-zero block means the IMU setting never
/// took, and publishing it would stream a dead sensor.
private func steamControllerMotion(_ packet: UnsafeBufferPointer<UInt8>) -> MotionSample? {
    let ax = Int32(steamLe16(packet, SteamPacketLayout.accel))
    let ay = Int32(steamLe16(packet, SteamPacketLayout.accel + 2))
    let az = Int32(steamLe16(packet, SteamPacketLayout.accel + 4))
    let gx = Int32(steamLe16(packet, SteamPacketLayout.gyro))
    let gy = Int32(steamLe16(packet, SteamPacketLayout.gyro + 2))
    let gz = Int32(steamLe16(packet, SteamPacketLayout.gyro + 4))
    let silent = (ax | ay | az | gx | gy | gz) == 0
    guard !silent else { return nil }
    return MotionSample(
        gyroX: steamGyroToWire(gx),
        gyroY: steamGyroToWire(gz),
        gyroZ: steamGyroToWire(gy),
        accelX: steamAccelToWire(ax),
        accelY: steamAccelToWire(az),
        accelZ: steamAccelToWire(-ay)
    )
}

// MARK: - Feature reports

/// Which way a configuration runs: quiet when Dish starts reading, restore
/// on every release, or the pad stays mute as a desktop mouse.
public enum SteamConfigStage: CaseIterable, Equatable, Sendable {
    case quiet
    case restore
}

/// Every feature report is one whole 64-byte report; report id 0 carries no
/// id byte on the wire, so the message starts the buffer.
public let steamFeatureReportBytes = 64

/// {message id, payload length, payload}, the ids and the shortest working
/// sequences the Linux driver uses.
private let clearDigitalMappings: [UInt8] = [0x81, 0x00]
/// Left and right trackpad mode none (the mouse goes quiet), IMU mode raw
/// accel and raw gyro.
private let quietSettings: [UInt8] = [0x87, 0x09, 0x07, 0x07, 0x00, 0x08, 0x07, 0x00, 0x30, 0x18, 0x00]
private let defaultDigitalMappings: [UInt8] = [0x85, 0x00]
private let loadDefaultSettings: [UInt8] = [0x8E, 0x00]
/// Loading the defaults leaves the right pad silent; SDL names its
/// absolute-mouse mode back.
private let rightPadMouse: [UInt8] = [0x87, 0x03, 0x08, 0x00, 0x00]
/// `ID_DONGLE_GET_WIRELESS_STATE`: the receiver answers with a connect or
/// disconnect event on the slot's input.
private let receiverStateRequest: [UInt8] = [0xB4, 0x00]

public func steamConfigReports(_ stage: SteamConfigStage) -> [[UInt8]] {
    steamConfigMessages(stage).map(steamFeatureReport)
}

private func steamConfigMessages(_ stage: SteamConfigStage) -> [[UInt8]] {
    switch stage {
    case .quiet: [clearDigitalMappings, quietSettings]
    case .restore: [defaultDigitalMappings, loadDefaultSettings, rightPadMouse]
    }
}

/// Asks a receiver's slot whether its controller is connected.
public func steamReceiverStateRequest() -> [UInt8] {
    steamFeatureReport(receiverStateRequest)
}

private func steamFeatureReport(_ message: [UInt8]) -> [UInt8] {
    message + [UInt8](repeating: 0, count: steamFeatureReportBytes - message.count)
}
