// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// The Moonlight control-stream contract as Wolf's MIT source and docs give it
// (control.hpp, control-specs.adoc, input-data.adoc), the same facts the
// other three clients pin. Every value here is read by an encoder or a
// decoder in this directory and pinned by a vector in its tests.

import Foundation

public enum MoonlightProtocol {
    public static let httpPort: UInt16 = 47989
    public static let httpsPort: UInt16 = 47984
    /// The RTSP port when the launch reply's `sessionUrl0` names none.
    public static let defaultRtspPort: UInt16 = 48010
    public static let bonjourType = "_nvstream._tcp"
    /// A Moonlight session carries four pads and no more.
    public static let maxPads = 4

    // MARK: - Control packet types, u16 little-endian

    public static let packetEncrypted: UInt16 = 0x0001
    /// Wolf's control.hpp says 0x0109. The GFE-era docs say 0x0100, and the
    /// decoder reads that one as a termination too.
    public static let packetTermination: UInt16 = 0x0109
    public static let packetTerminationLegacy: UInt16 = 0x0100
    public static let packetPeriodicPing: UInt16 = 0x0200
    public static let packetInputData: UInt16 = 0x0206
    public static let eventRumbleData: UInt16 = 0x010B
    public static let eventRumbleTriggers: UInt16 = 0x5500
    public static let eventMotion: UInt16 = 0x5501
    public static let eventRgbLed: UInt16 = 0x5502
    /// The one big-endian field of the family: the reason a session ends.
    public static let terminateReasonGraceful: UInt32 = 0x8003_0023

    // MARK: - Message lengths, control header included

    public static let controlHeaderLength = 4
    public static let controllerMultiLength = 38
    /// Eight body bytes, not the seven its fields add up to: the host reads
    /// a naturally aligned struct, so the u32 sits at offset 4.
    public static let controllerArrivalLength = 20
    public static let controllerTouchLength = 32
    public static let controllerMotionLength = 28
    public static let controllerBatteryLength = 16
    public static let mouseMoveRelLength = 16
    public static let mouseButtonLength = 13
    public static let mouseScrollLength = 18
    /// The form a real client sends, captured by Wolf: an eight-byte body.
    public static let periodicPingLength = 12
    public static let terminationLength = 8

    /// The CONTROLLER_MULTI struct's fixed words, in order of appearance.
    public static let multiHeaderWord: UInt16 = 0x001A
    public static let multiMidWord: UInt16 = 0x0014
    public static let multiTailWordA: UInt16 = 0x009C
    public static let multiTailWordB: UInt16 = 0x0055
}

/// The input type word inside INPUT_DATA, u32 little-endian.
public enum MoonlightInputType {
    public static let mouseMoveRel: UInt32 = 0x0000_0007
    public static let mouseButtonDown: UInt32 = 0x0000_0008
    public static let mouseButtonUp: UInt32 = 0x0000_0009
    public static let mouseScroll: UInt32 = 0x0000_000A
    public static let controllerMulti: UInt32 = 0x0000_000C
    public static let controllerArrival: UInt32 = 0x5500_0004
    public static let controllerTouch: UInt32 = 0x5500_0005
    public static let controllerMotion: UInt32 = 0x5500_0006
    public static let controllerBattery: UInt32 = 0x5500_0007
}

/// The 32-bit button field: XUSB's low sixteen, then the extended buttons
/// the second word carries.
public enum MoonlightButton {
    public static let dpadUp: UInt32 = 0x0001
    public static let dpadDown: UInt32 = 0x0002
    public static let dpadLeft: UInt32 = 0x0004
    public static let dpadRight: UInt32 = 0x0008
    public static let start: UInt32 = 0x0010
    public static let back: UInt32 = 0x0020
    public static let leftStick: UInt32 = 0x0040
    public static let rightStick: UInt32 = 0x0080
    public static let leftButton: UInt32 = 0x0100
    public static let rightButton: UInt32 = 0x0200
    public static let home: UInt32 = 0x0400
    /// XUSB's one unassigned bit, which the satellite protocol uses for the
    /// DualSense's mic mute; no Moonlight button lives there.
    public static let reservedMicMute: UInt32 = 0x0800
    public static let buttonA: UInt32 = 0x1000
    public static let buttonB: UInt32 = 0x2000
    public static let buttonX: UInt32 = 0x4000
    public static let buttonY: UInt32 = 0x8000
    public static let paddle1: UInt32 = 0x010000
    public static let paddle2: UInt32 = 0x020000
    public static let paddle3: UInt32 = 0x040000
    public static let paddle4: UInt32 = 0x080000
    public static let touchpad: UInt32 = 0x100000
    public static let misc: UInt32 = 0x200000
}

/// The capability byte of CONTROLLER_ARRIVAL.
public enum MoonlightCapability {
    public static let analogTriggers: UInt8 = 0x01
    public static let rumble: UInt8 = 0x02
    public static let triggerRumble: UInt8 = 0x04
    public static let touchpad: UInt8 = 0x08
    public static let accelerometer: UInt8 = 0x10
    public static let gyro: UInt8 = 0x20
    public static let battery: UInt8 = 0x40
    public static let rgbLed: UInt8 = 0x80
}

public enum MoonlightControllerType {
    public static let unknown: UInt8 = 0x00
    public static let xbox: UInt8 = 0x01
    public static let playStation: UInt8 = 0x02
    public static let nintendo: UInt8 = 0x03
    /// A client-side pick that never reaches the wire: resolved to one of
    /// the three before the arrival is sent.
    public static let auto: UInt8 = 0xFF
}

public enum MoonlightBatteryState {
    public static let unknown: UInt8 = 0x00
    public static let notPresent: UInt8 = 0x01
    public static let discharging: UInt8 = 0x02
    public static let charging: UInt8 = 0x03
    public static let notCharging: UInt8 = 0x04
    public static let full: UInt8 = 0x05
    public static let percentageUnknown: UInt8 = 0xFF
}

public enum MoonlightTouchEvent {
    public static let down: UInt8 = 0x01
    public static let up: UInt8 = 0x02
    public static let move: UInt8 = 0x03
}

public enum MoonlightMotionType {
    public static let accelerometer: UInt8 = 0x01
    public static let gyro: UInt8 = 0x02
}

public enum MoonlightMouseButton {
    public static let left: UInt8 = 0x01
    public static let middle: UInt8 = 0x02
    public static let right: UInt8 = 0x03
}
