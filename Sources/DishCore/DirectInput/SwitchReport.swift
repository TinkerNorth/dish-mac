// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// The Switch standard full input report 0x30, which the Pro, the N64 and
// the SNES Online pads all send over USB and Bluetooth once Apple's driver
// has made the handshake: the battery byte, three button bytes (right,
// shared, left) with the triggers as digital bits, two packed 12-bit sticks,
// then up to three IMU frames. Ported from dish-android's
// `decodeSwitchProUsb` and `decodeSwitchN64Usb`; the byte layout is the one
// Linux's hid-nintendo documents. Decoding reads the caller's buffer in
// place and builds no collection.

import Foundation

/// Which pad sent the report, which picks its button tables.
public enum SwitchPadKind: Equatable, Sendable {
    case pro
    case n64
    /// Pro buttons, no sticks and no IMU on the pad.
    case snes
}

/// A pad's charge as MSG_BATTERY carries it: a percent or
/// `ProtocolConstants.batteryLevelUnknown`, and the wire status.
public struct PadBattery: Equatable, Sendable {
    public let level: UInt8
    public let status: BatteryStatus

    public init(level: UInt8, status: BatteryStatus) {
        self.level = level
        self.status = status
    }
}

/// One decoded report: the XUSB state, the motion when the pad has an IMU
/// and the report carries a frame, and the battery every report carries.
public struct SwitchReading: Equatable, Sendable {
    public let report: GamepadReport
    public let motion: MotionSample?
    public let battery: PadBattery
}

enum SwitchReportLayout {
    static let reportId: UInt8 = 0x30
    static let minLength = 12
    static let batteryByte = 2
    static let rightByte = 3
    static let sharedByte = 4
    static let leftByte = 5
    static let leftStick = 6
    static let rightStick = 9
    static let triggerBit: UInt8 = 0x80
    static let n64ZrBit: UInt8 = 0x08
    static let fullTrigger: UInt8 = 255
}

struct ButtonBit {
    let mask: UInt8
    let button: WireButton
}

/// Mapped by position, as for the DualShock 4: Switch Y (left face) is XUSB
/// X, X (top) is Y, B (bottom) is A, A (right) is B.
let switchProRightBits = [
    ButtonBit(mask: 0x01, button: .faceX), ButtonBit(mask: 0x02, button: .faceY),
    ButtonBit(mask: 0x04, button: .faceA), ButtonBit(mask: 0x08, button: .faceB),
    ButtonBit(mask: 0x40, button: .rightShoulder)
]

/// Minus, Plus, the stick clicks and Home. Capture has no XUSB bit.
let switchProSharedBits = [
    ButtonBit(mask: 0x01, button: .back), ButtonBit(mask: 0x02, button: .start),
    ButtonBit(mask: 0x04, button: .rightThumb), ButtonBit(mask: 0x08, button: .leftThumb),
    ButtonBit(mask: 0x10, button: .guide)
]

let switchLeftBits = [
    ButtonBit(mask: 0x01, button: .dpadDown), ButtonBit(mask: 0x02, button: .dpadUp),
    ButtonBit(mask: 0x04, button: .dpadRight), ButtonBit(mask: 0x08, button: .dpadLeft),
    ButtonBit(mask: 0x40, button: .leftShoulder)
]

let n64RightBits = [
    ButtonBit(mask: 0x04, button: .faceB), ButtonBit(mask: 0x08, button: .faceA),
    ButtonBit(mask: 0x40, button: .rightShoulder)
]

/// Start, Home as Guide and Capture as Back: Android's N64 policy.
let n64SharedBits = [
    ButtonBit(mask: 0x02, button: .start), ButtonBit(mask: 0x10, button: .guide),
    ButtonBit(mask: 0x20, button: .back)
]

struct CButtonBit {
    let byte: Int
    let mask: UInt8
    let button: CButton
}

let n64CButtonBits = [
    CButtonBit(byte: SwitchReportLayout.rightByte, mask: 0x01, button: .up),
    CButtonBit(byte: SwitchReportLayout.rightByte, mask: 0x80, button: .down),
    CButtonBit(byte: SwitchReportLayout.rightByte, mask: 0x02, button: .left),
    CButtonBit(byte: SwitchReportLayout.sharedByte, mask: 0x01, button: .right)
]

/// hid-nintendo's bat_con: the charge in five steps in bits 7..5, charging
/// in bit 4, host power in bit 0. The percent is the step's midpoint.
enum SwitchBatteryLayout {
    static let stepShift: UInt8 = 5
    static let chargingBit: UInt8 = 0x10
    static let hostPoweredBit: UInt8 = 0x01
    static let stepPercent: [UInt8] = [5, 25, 50, 75, 100]
    static let fullStep: UInt8 = 4
}

func heldButtons(_ byte: UInt8, _ table: [ButtonBit]) -> WireButtonWord {
    var word = WireButtonWord()
    for bit in table where byte & bit.mask != 0 {
        word.insert(bit.button)
    }
    return word
}

/// Three fixed arguments rather than a variadic, which would build an array
/// per report.
private func union(_ right: WireButtonWord, _ shared: WireButtonWord, _ left: WireButtonWord) -> UInt16 {
    right.rawValue | shared.rawValue | left.rawValue
}

private func fullTrigger(_ byte: UInt8, _ bit: UInt8) -> UInt8 {
    byte & bit != 0 ? SwitchReportLayout.fullTrigger : 0
}

public func isSwitchInputReport(_ report: UnsafeBufferPointer<UInt8>) -> Bool {
    let longEnough = report.count >= SwitchReportLayout.minLength
    return longEnough && report[0] == SwitchReportLayout.reportId
}

public func decodeSwitchBattery(_ batCon: UInt8) -> PadBattery {
    let step = batCon >> SwitchBatteryLayout.stepShift
    let charging = batCon & SwitchBatteryLayout.chargingBit != 0
    let hostPowered = batCon & SwitchBatteryLayout.hostPoweredBit != 0
    let stepIsKnown = step <= SwitchBatteryLayout.fullStep
    let level = stepIsKnown ? SwitchBatteryLayout.stepPercent[Int(step)] : ProtocolConstants.batteryLevelUnknown
    let toppedOffOnTheCable = hostPowered && step == SwitchBatteryLayout.fullStep
    if charging { return PadBattery(level: level, status: .charging) }
    return PadBattery(level: level, status: toppedOffOnTheCable ? .full : .discharging)
}

/// Nil when the bytes are not a 0x30 report long enough to read.
public func decodeSwitchReport(
    _ report: UnsafeBufferPointer<UInt8>,
    kind: SwitchPadKind,
    calibration: inout SwitchStickCalibration
) -> SwitchReading? {
    guard isSwitchInputReport(report) else { return nil }
    switch kind {
    case .pro: return decodeSwitchPro(report, calibration: &calibration)
    case .n64: return decodeSwitchN64(report, calibration: &calibration)
    case .snes: return decodeSwitchSnes(report)
    }
}

private func proButtons(_ report: UnsafeBufferPointer<UInt8>) -> GamepadReport {
    let right = report[SwitchReportLayout.rightByte]
    let shared = report[SwitchReportLayout.sharedByte]
    let left = report[SwitchReportLayout.leftByte]
    let buttons = union(
        heldButtons(right, switchProRightBits),
        heldButtons(shared, switchProSharedBits),
        heldButtons(left, switchLeftBits)
    )
    return GamepadReport(
        buttons: buttons,
        lt: fullTrigger(left, SwitchReportLayout.triggerBit),
        rt: fullTrigger(right, SwitchReportLayout.triggerBit)
    )
}

private func decodeSwitchPro(_ report: UnsafeBufferPointer<UInt8>, calibration: inout SwitchStickCalibration) -> SwitchReading {
    var state = proButtons(report)
    let left = decodeSwitchStick(report, at: SwitchReportLayout.leftStick, x: &calibration.lx, y: &calibration.ly)
    let right = decodeSwitchStick(report, at: SwitchReportLayout.rightStick, x: &calibration.rx, y: &calibration.ry)
    state.lx = left.x
    state.ly = left.y
    state.rx = right.x
    state.ry = right.y
    let motion = switchMotion(sumSwitchImuFrames(report))
    let battery = decodeSwitchBattery(report[SwitchReportLayout.batteryByte])
    return SwitchReading(report: state, motion: motion, battery: battery)
}

private func decodeSwitchSnes(_ report: UnsafeBufferPointer<UInt8>) -> SwitchReading {
    let battery = decodeSwitchBattery(report[SwitchReportLayout.batteryByte])
    return SwitchReading(report: proButtons(report), motion: nil, battery: battery)
}

private func n64CButtons(_ report: UnsafeBufferPointer<UInt8>) -> CButtonWord {
    var word = CButtonWord()
    for bit in n64CButtonBits where report[bit.byte] & bit.mask != 0 {
        word.insert(bit.button)
    }
    return word
}

/// The C buttons rail the right stick through the profile path's own rule,
/// so both paths read an N64 pad the same way.
private func decodeSwitchN64(_ report: UnsafeBufferPointer<UInt8>, calibration: inout SwitchStickCalibration) -> SwitchReading {
    let right = report[SwitchReportLayout.rightByte]
    let shared = report[SwitchReportLayout.sharedByte]
    let left = report[SwitchReportLayout.leftByte]
    let buttons = union(heldButtons(right, n64RightBits), heldButtons(shared, n64SharedBits), heldButtons(left, switchLeftBits))
    let stick = decodeSwitchStick(report, at: SwitchReportLayout.leftStick, x: &calibration.lx, y: &calibration.ly)
    let cButtons = n64CButtons(report)
    let railX = stickRail(positive: cButtons.contains(.right), negative: cButtons.contains(.left))
    let railY = stickRail(positive: cButtons.contains(.up), negative: cButtons.contains(.down))
    let state = GamepadReport(
        buttons: buttons,
        lt: fullTrigger(left, SwitchReportLayout.triggerBit),
        rt: fullTrigger(shared, SwitchReportLayout.n64ZrBit),
        lx: stick.x,
        ly: stick.y,
        rx: scaleAxis(railX, max: wireStickMax),
        ry: scaleAxis(railY, max: wireStickMax)
    )
    let battery = decodeSwitchBattery(report[SwitchReportLayout.batteryByte])
    return SwitchReading(report: state, motion: nil, battery: battery)
}
