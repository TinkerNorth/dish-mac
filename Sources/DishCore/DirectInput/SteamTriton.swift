// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// The 2026 Steam Controller ("Triton": 28de:1302 wired, 28de:1304 Puck and
// 28de:1305 receiver, a controller per receiver interface 2...5), read from
// SDL's `SDL_hidapi_steam_triton.c` and `controller_structs.h`: numbered
// input reports (the state, the battery, the receiver's wireless status),
// the feature report that turns lizard mode off and the IMU on, and the
// haptic rumble output report. The firmware's watchdog turns lizard mode
// back on, so the reader re-sends the setting every few seconds while it
// reads the pad. The state layout agrees with the Linux `hid-steam` tables.
// Decoding reads the caller's buffer in place and builds no collection.

import Foundation

public enum TritonReportId {
    public static let state: UInt8 = 0x42
    public static let battery: UInt8 = 0x43
    public static let stateBle: UInt8 = 0x45
    public static let wirelessX: UInt8 = 0x46
    public static let stateTimestamp: UInt8 = 0x47
    public static let wireless: UInt8 = 0x79
    public static let controllerFeature: UInt8 = 0x01
    public static let hapticRumble: UInt8 = 0x80
}

/// Offsets past the report id. Every state report shares SDL's
/// `TritonMTUNoQuat_t` through the gyro: the full report appends a
/// quaternion and the timestamped one moves only the pads and timestamps.
enum TritonLayout {
    static let stateLength = 46
    static let batteryLength = 15
    static let wirelessLength = 2
    static let buttons = 2
    static let leftTrigger = 6
    static let rightTrigger = 8
    static let leftStick = 10
    static let rightStick = 14
    static let accel = 34
    static let gyro = 40
    static let chargeState = 1
    static let batteryLevel = 2
    static let wirelessState = 1
    static let disconnected: UInt8 = 1
    static let connected: UInt8 = 2
    static let triggerMax: Int32 = 32767
    static let percentMax: UInt8 = 100
}

/// `EChargeState`; reset and source-validate are SDL's "error state?".
enum TritonChargeState {
    static let discharging: UInt8 = 1
    static let charging: UInt8 = 2
    static let chargingDone: UInt8 = 4
}

enum TritonButtonMask {
    static let buttonA: UInt32 = 0x0000_0001
    static let buttonB: UInt32 = 0x0000_0002
    static let buttonX: UInt32 = 0x0000_0004
    static let buttonY: UInt32 = 0x0000_0008
    static let rightStickClick: UInt32 = 0x0000_0020
    static let view: UInt32 = 0x0000_0040
    static let rightShoulder: UInt32 = 0x0000_0200
    static let dpadDown: UInt32 = 0x0000_0400
    static let dpadRight: UInt32 = 0x0000_0800
    static let dpadLeft: UInt32 = 0x0000_1000
    static let dpadUp: UInt32 = 0x0000_2000
    static let menu: UInt32 = 0x0000_4000
    static let leftStickClick: UInt32 = 0x0000_8000
    static let steam: UInt32 = 0x0001_0000
    static let leftShoulder: UInt32 = 0x0008_0000
}

/// SDL's mapping: View is Start and Menu is Back (hid-steam calls the bits
/// Start and Select). The quick-access button, the four grip paddles, the
/// pad and trigger clicks and the touch senses have no XUSB bit.
let tritonButtonBits = [
    SteamButtonBit(mask: TritonButtonMask.buttonA, button: .faceA),
    SteamButtonBit(mask: TritonButtonMask.buttonB, button: .faceB),
    SteamButtonBit(mask: TritonButtonMask.buttonX, button: .faceX),
    SteamButtonBit(mask: TritonButtonMask.buttonY, button: .faceY),
    SteamButtonBit(mask: TritonButtonMask.leftShoulder, button: .leftShoulder),
    SteamButtonBit(mask: TritonButtonMask.rightShoulder, button: .rightShoulder),
    SteamButtonBit(mask: TritonButtonMask.view, button: .start),
    SteamButtonBit(mask: TritonButtonMask.menu, button: .back),
    SteamButtonBit(mask: TritonButtonMask.steam, button: .guide),
    SteamButtonBit(mask: TritonButtonMask.leftStickClick, button: .leftThumb),
    SteamButtonBit(mask: TritonButtonMask.rightStickClick, button: .rightThumb),
    SteamButtonBit(mask: TritonButtonMask.dpadUp, button: .dpadUp),
    SteamButtonBit(mask: TritonButtonMask.dpadDown, button: .dpadDown),
    SteamButtonBit(mask: TritonButtonMask.dpadLeft, button: .dpadLeft),
    SteamButtonBit(mask: TritonButtonMask.dpadRight, button: .dpadRight)
]

/// Nil for a report this decoder does not read, or one too short to.
public func decodeTritonReport(_ report: UnsafeBufferPointer<UInt8>) -> SteamReading? {
    guard let reportId = report.first else { return nil }
    switch reportId {
    case TritonReportId.state, TritonReportId.stateBle, TritonReportId.stateTimestamp: return tritonState(report)
    case TritonReportId.battery: return tritonBattery(report)
    case TritonReportId.wireless, TritonReportId.wirelessX: return tritonLink(report)
    default: return nil
    }
}

/// The four button bytes as one little-endian word, read one by one so a
/// report builds nothing.
private func tritonButtonWord(_ report: UnsafeBufferPointer<UInt8>) -> UInt32 {
    let byte0 = UInt32(report[TritonLayout.buttons])
    let byte1 = UInt32(report[TritonLayout.buttons + 1]) << 8
    let byte2 = UInt32(report[TritonLayout.buttons + 2]) << 16
    let byte3 = UInt32(report[TritonLayout.buttons + 3]) << 24
    return byte0 | byte1 | byte2 | byte3
}

/// The sticks are up-positive, as the wire is; the triggers run 0...32767.
private func tritonState(_ report: UnsafeBufferPointer<UInt8>) -> SteamReading? {
    guard report.count >= TritonLayout.stateLength else { return nil }
    let buttons = steamButtons(tritonButtonWord(report), tritonButtonBits)
    let state = GamepadReport(
        buttons: buttons.rawValue,
        lt: tritonTrigger(steamLe16(report, TritonLayout.leftTrigger)),
        rt: tritonTrigger(steamLe16(report, TritonLayout.rightTrigger)),
        lx: steamLe16(report, TritonLayout.leftStick),
        ly: steamLe16(report, TritonLayout.leftStick + 2),
        rx: steamLe16(report, TritonLayout.rightStick),
        ry: steamLe16(report, TritonLayout.rightStick + 2)
    )
    return .state(state, motion: tritonMotion(report))
}

func tritonTrigger(_ raw: Int16) -> UInt8 {
    let pulled = max(Int32(raw), 0)
    return UInt8(clamping: pulled * 255 / TritonLayout.triggerMax)
}

/// SDL's axes onto the wire: pitch on gyro X, yaw on gyro Z, roll on minus
/// gyro Y; accel X, Z and minus Y. An all-zero block is a sensor that was
/// never switched on.
private func tritonMotion(_ report: UnsafeBufferPointer<UInt8>) -> MotionSample? {
    let ax = Int32(steamLe16(report, TritonLayout.accel))
    let ay = Int32(steamLe16(report, TritonLayout.accel + 2))
    let az = Int32(steamLe16(report, TritonLayout.accel + 4))
    let gx = Int32(steamLe16(report, TritonLayout.gyro))
    let gy = Int32(steamLe16(report, TritonLayout.gyro + 2))
    let gz = Int32(steamLe16(report, TritonLayout.gyro + 4))
    let silent = (ax | ay | az | gx | gy | gz) == 0
    guard !silent else { return nil }
    return MotionSample(
        gyroX: steamGyroToWire(gx),
        gyroY: steamGyroToWire(gz),
        gyroZ: steamGyroToWire(-gy),
        accelX: steamAccelToWire(ax),
        accelY: steamAccelToWire(az),
        accelZ: steamAccelToWire(-ay)
    )
}

private func tritonBattery(_ report: UnsafeBufferPointer<UInt8>) -> SteamReading? {
    guard report.count >= TritonLayout.batteryLength else { return nil }
    let level = tritonBatteryLevel(report[TritonLayout.batteryLevel])
    return .battery(PadBattery(level: level, status: tritonBatteryStatus(report[TritonLayout.chargeState])))
}

/// SDL passes the byte through; a value past a percent reads as unknown.
func tritonBatteryLevel(_ byte: UInt8) -> UInt8 {
    byte <= TritonLayout.percentMax ? byte : ProtocolConstants.batteryLevelUnknown
}

func tritonBatteryStatus(_ chargeState: UInt8) -> BatteryStatus {
    switch chargeState {
    case TritonChargeState.discharging: .discharging
    case TritonChargeState.charging: .charging
    case TritonChargeState.chargingDone: .full
    default: .unknown
    }
}

private func tritonLink(_ report: UnsafeBufferPointer<UInt8>) -> SteamReading? {
    guard report.count >= TritonLayout.wirelessLength else { return nil }
    switch report[TritonLayout.wirelessState] {
    case TritonLayout.connected: return .link(.connected)
    case TritonLayout.disconnected: return .link(.disconnected)
    default: return nil
    }
}

// MARK: - What Dish sends

/// `HID_FEATURE_REPORT_BYTES`, the report id included.
public let tritonFeatureReportBytes = 64

/// SDL's `ID_SET_SETTINGS_VALUES` with one `ControllerSetting` (number,
/// value LE): `SETTING_LIZARD_MODE` (9) = `LIZARD_MODE_OFF`.
private let lizardOffSetting: [UInt8] = [0x87, 0x03, 0x09, 0x00, 0x00]
/// `SETTING_IMU_MODE` (48) = raw accel | raw gyro.
private let sensorsOnSetting: [UInt8] = [0x87, 0x03, 0x30, 0x18, 0x00]

/// Lizard mode off, on the controller's feature report.
public func tritonLizardOffReport() -> [UInt8] {
    tritonFeatureReport(lizardOffSetting)
}

/// The IMU on, raw: what SDL sends when sensors are enabled.
public func tritonSensorsOnReport() -> [UInt8] {
    tritonFeatureReport(sensorsOnSetting)
}

private func tritonFeatureReport(_ message: [UInt8]) -> [UInt8] {
    let framed = [TritonReportId.controllerFeature] + message
    return framed + [UInt8](repeating: 0, count: tritonFeatureReportBytes - framed.count)
}

/// `ID_OUT_REPORT_HAPTIC_RUMBLE`: type 0 and intensity 0, then each side's
/// speed and gain, as SDL sends it: the strong motor on the left.
public func tritonRumbleReport(left: UInt16, right: UInt16) -> [UInt8] {
    [
        TritonReportId.hapticRumble, 0x00, 0x00, 0x00,
        UInt8(truncatingIfNeeded: left), UInt8(truncatingIfNeeded: left >> 8), 0x00,
        UInt8(truncatingIfNeeded: right), UInt8(truncatingIfNeeded: right >> 8), 0x00
    ]
}

// MARK: - Rumble between host commands

public enum TritonRumbleRule {
    /// SDL's `TRITON_RUMBLE_RESEND_INTERVAL_MS`: inside the firmware's
    /// ~50 ms safety stop.
    public static let resendMs: Int64 = 40
    /// The longest one command runs the motors, the GameController path's
    /// `RumbleActuator.maxHoldMs`: the satellite re-sends a held level and
    /// sends the stop itself, so this only outlives a dead host.
    public static let maxHoldMs: Int64 = 1500
    /// SDL's lizard-mode refresh: the firmware's watchdog turns it back on.
    public static let lizardRefreshMs: Int64 = 3000
}

/// The pad's rumble between host commands: the level, re-sent until its
/// hold ends or a zero command stops it.
public struct TritonRumble: Equatable, Sendable {
    public private(set) var left: UInt16 = 0
    public private(set) var right: UInt16 = 0
    /// When the level ends; nil while the motors are still.
    public private(set) var endsAtMs: Int64?
    private var lastSentMs: Int64 = 0

    public init() {}

    public var running: Bool {
        endsAtMs != nil
    }

    /// The report a host command sends at once; a zero level stops now.
    public mutating func command(strong: UInt16, weak: UInt16, durationMs: UInt16, nowMs: Int64) -> [UInt8] {
        let still = strong == 0 && weak == 0
        left = strong
        right = weak
        endsAtMs = still ? nil : nowMs + Self.holdMs(durationMs)
        lastSentMs = nowMs
        return tritonRumbleReport(left: left, right: right)
    }

    /// The report due at this tick: the level again every `resendMs`, and
    /// the stop once when the hold ends.
    public mutating func tick(nowMs: Int64) -> [UInt8]? {
        guard let endsAtMs else { return nil }
        if nowMs >= endsAtMs { return command(strong: 0, weak: 0, durationMs: 0, nowMs: nowMs) }
        guard nowMs - lastSentMs >= TritonRumbleRule.resendMs else { return nil }
        lastSentMs = nowMs
        return tritonRumbleReport(left: left, right: right)
    }

    /// A continuous command (0) holds for the safety net, as does a longer one.
    private static func holdMs(_ durationMs: UInt16) -> Int64 {
        let asked = Int64(durationMs)
        return asked == 0 ? TritonRumbleRule.maxHoldMs : min(asked, TritonRumbleRule.maxHoldMs)
    }
}
