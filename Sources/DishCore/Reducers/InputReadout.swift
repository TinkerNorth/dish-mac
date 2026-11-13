// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// What the input inspector shows of one wire report: which buttons the XUSB
// word and the protocol 4 extended-buttons word hold down, and the sticks,
// triggers, motion and touch in human units. The button tables carry the
// layout the report builders write, so the inspector cannot name a bit the
// wire does not carry.

import Foundation

public enum WireButton: CaseIterable, Equatable, Sendable {
    case dpadUp
    case dpadDown
    case dpadLeft
    case dpadRight
    case start
    case back
    case leftThumb
    case rightThumb
    case leftShoulder
    case rightShoulder
    case guide
    case micMute
    case faceA
    case faceB
    case faceX
    case faceY

    /// The XUSB bit, 0x0800 being the DualSense mic-mute button protocol 2
    /// put in the word's one unassigned slot.
    public var bit: UInt16 {
        switch self {
        case .dpadUp: 0x0001
        case .dpadDown: 0x0002
        case .dpadLeft: 0x0004
        case .dpadRight: 0x0008
        case .start: 0x0010
        case .back: 0x0020
        case .leftThumb: 0x0040
        case .rightThumb: 0x0080
        case .leftShoulder: 0x0100
        case .rightShoulder: 0x0200
        case .guide: 0x0400
        case .micMute: 0x0800
        case .faceA: 0x1000
        case .faceB: 0x2000
        case .faceX: 0x4000
        case .faceY: 0x8000
        }
    }
}

/// The buttons a report's XUSB word holds down, in wire-bit order.
public func pressedButtons(_ wButtons: UInt16) -> [WireButton] {
    WireButton.allCases.filter { wButtons & $0.bit != 0 }
}

public enum ExtendedButton: CaseIterable, Equatable, Sendable {
    case rightPaddle1
    case leftPaddle1
    case rightPaddle2
    case leftPaddle2
    case misc1
    case leftPadClick
    case rightPadClick
    case leftTriggerClick
    case rightTriggerClick
    case leftStickTouch
    case rightStickTouch
    case leftGripTouch
    case rightGripTouch

    public var bit: UInt32 {
        switch self {
        case .rightPaddle1: ProtocolConstants.extButtonRightPaddle1
        case .leftPaddle1: ProtocolConstants.extButtonLeftPaddle1
        case .rightPaddle2: ProtocolConstants.extButtonRightPaddle2
        case .leftPaddle2: ProtocolConstants.extButtonLeftPaddle2
        case .misc1: ProtocolConstants.extButtonMisc1
        case .leftPadClick: ProtocolConstants.extButtonLeftPadClick
        case .rightPadClick: ProtocolConstants.extButtonRightPadClick
        case .leftTriggerClick: ProtocolConstants.extButtonLeftTriggerClick
        case .rightTriggerClick: ProtocolConstants.extButtonRightTriggerClick
        case .leftStickTouch: ProtocolConstants.extButtonLeftStickTouch
        case .rightStickTouch: ProtocolConstants.extButtonRightStickTouch
        case .leftGripTouch: ProtocolConstants.extButtonLeftGripTouch
        case .rightGripTouch: ProtocolConstants.extButtonRightGripTouch
        }
    }
}

public func pressedExtendedButtons(_ extButtons: UInt32) -> [ExtendedButton] {
    ExtendedButton.allCases.filter { extButtons & $0.bit != 0 }
}

public enum InputReadout {
    /// A stick axis as a fraction of full deflection, -1...1. Divided by
    /// 32768 like dish-android's inspector, so both clients read one sample
    /// the same.
    public static let stickScale: Float = 32768
    public static let triggerScale: Float = 255
    /// The motion wire scale: full scale is 2000 deg/s for the gyro and 4 g
    /// for the accelerometer at 32767.
    public static let motionFullScale: Float = 32767
    public static let gyroFullScaleDps: Float = 2000
    public static let accelFullScaleG: Float = 4
    /// A touch coordinate as a fraction across the pad, 0...1: the wire maps
    /// the pad's first column or row to -32768 and its last to 32767.
    public static let touchOffset: Float = 32768
    public static let touchSpan: Float = 65535

    public static func stickFraction(_ axis: Int16) -> Float {
        Float(axis) / stickScale
    }

    public static func stickSample(x: Int16, y: Int16) -> StickSample {
        StickSample(x: stickFraction(x), y: stickFraction(y))
    }

    public static func triggerFraction(_ trigger: UInt8) -> Float {
        Float(trigger) / triggerScale
    }

    public static func gyroDegreesPerSecond(_ raw: Int16) -> Float {
        Float(raw) * gyroFullScaleDps / motionFullScale
    }

    public static func accelG(_ raw: Int16) -> Float {
        Float(raw) * accelFullScaleG / motionFullScale
    }

    public static func touchFraction(_ coordinate: Int16) -> Float {
        (Float(coordinate) + touchOffset) / touchSpan
    }
}
