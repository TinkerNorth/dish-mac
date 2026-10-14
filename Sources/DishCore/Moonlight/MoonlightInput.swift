// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// The decrypted control-stream plaintext of every message the dish sends a
// Moonlight host. Each begins with the control header `[type u16][len u16]`;
// an INPUT_DATA message continues with `[data size u32 BIG-endian][input
// type u32]` and the struct body. Sealing and ENet framing happen elsewhere.

import Foundation

public enum MoonlightInput {
    /// One pad's state as CONTROLLER_MULTI carries it. `buttons` is the full
    /// 32-bit field, split on the wire into its low and high words; a pad
    /// whose bit is cleared from `activeMask` is being unplugged.
    public struct PadFrame: Equatable, Sendable {
        public var controller: UInt8
        public var activeMask: UInt16
        public var buttons: UInt32
        public var leftTrigger: UInt8
        public var rightTrigger: UInt8
        public var leftX: Int16
        public var leftY: Int16
        public var rightX: Int16
        public var rightY: Int16

        public init(
            controller: UInt8,
            activeMask: UInt16,
            buttons: UInt32 = 0,
            leftTrigger: UInt8 = 0,
            rightTrigger: UInt8 = 0,
            leftX: Int16 = 0,
            leftY: Int16 = 0,
            rightX: Int16 = 0,
            rightY: Int16 = 0
        ) {
            self.controller = controller
            self.activeMask = activeMask
            self.buttons = buttons
            self.leftTrigger = leftTrigger
            self.rightTrigger = rightTrigger
            self.leftX = leftX
            self.leftY = leftY
            self.rightX = rightX
            self.rightY = rightY
        }
    }

    /// Which pad turned up, what the host should emulate it as, what it can do.
    public struct PadArrival: Equatable, Sendable {
        public var controller: UInt8
        public var type: UInt8
        public var capabilities: UInt8
        public var supportedButtons: UInt32

        public init(controller: UInt8, type: UInt8, capabilities: UInt8, supportedButtons: UInt32) {
            self.controller = controller
            self.type = type
            self.capabilities = capabilities
            self.supportedButtons = supportedButtons
        }
    }

    public static func controllerMulti(_ frame: PadFrame) -> Data {
        var writer = beginInput(length: MoonlightProtocol.controllerMultiLength, type: MoonlightInputType.controllerMulti)
        writer.u16LE(MoonlightProtocol.multiHeaderWord)
        writer.u16LE(UInt16(frame.controller))
        writer.u16LE(frame.activeMask)
        writer.u16LE(MoonlightProtocol.multiMidWord)
        writer.u16LE(UInt16(truncatingIfNeeded: frame.buttons))
        writer.u8(frame.leftTrigger)
        writer.u8(frame.rightTrigger)
        writer.i16LE(frame.leftX)
        writer.i16LE(frame.leftY)
        writer.i16LE(frame.rightX)
        writer.i16LE(frame.rightY)
        writer.u16LE(MoonlightProtocol.multiTailWordA)
        writer.u16LE(UInt16(truncatingIfNeeded: frame.buttons >> 16))
        writer.u16LE(MoonlightProtocol.multiTailWordB)
        return writer.data
    }

    /// The body is eight bytes: a reserved byte follows the capabilities so
    /// the button mask sits at offset 4, where the host's aligned struct
    /// reads it. Seven bytes made a live host read `capabilities [FF03]`.
    public static func controllerArrival(_ arrival: PadArrival) -> Data {
        var writer = beginInput(length: MoonlightProtocol.controllerArrivalLength, type: MoonlightInputType.controllerArrival)
        writer.u8(arrival.controller)
        writer.u8(arrival.type)
        writer.u8(arrival.capabilities)
        writer.u8(0)
        writer.u32LE(arrival.supportedButtons)
        return writer.data
    }

    /// One pointer on the emulated pad's touch surface; `x` and `y` are
    /// normalized 0...1, `pressure` 1 for a solid contact.
    public static func controllerTouch(controller: UInt8, event: UInt8, pointerId: UInt32, x: Float, y: Float, pressure: Float) -> Data {
        var writer = beginInput(length: MoonlightProtocol.controllerTouchLength, type: MoonlightInputType.controllerTouch)
        writer.u8(controller)
        writer.u8(event)
        writer.u16LE(0)
        writer.u32LE(pointerId)
        writer.f32LE(x)
        writer.f32LE(y)
        writer.f32LE(pressure)
        return writer.data
    }

    /// One IMU sample in the wire's units: gyro in degrees per second,
    /// accelerometer in metres per second squared.
    public static func controllerMotion(controller: UInt8, type: UInt8, x: Float, y: Float, z: Float) -> Data {
        var writer = beginInput(length: MoonlightProtocol.controllerMotionLength, type: MoonlightInputType.controllerMotion)
        writer.u8(controller)
        writer.u8(type)
        writer.u16LE(0)
        writer.f32LE(x)
        writer.f32LE(y)
        writer.f32LE(z)
        return writer.data
    }

    public static func controllerBattery(controller: UInt8, state: UInt8, percentage: UInt8) -> Data {
        var writer = beginInput(length: MoonlightProtocol.controllerBatteryLength, type: MoonlightInputType.controllerBattery)
        writer.u8(controller)
        writer.u8(state)
        writer.u8(percentage)
        writer.u8(0)
        return writer.data
    }

    /// The mouse deltas are the protocol's other big-endian fields.
    public static func mouseMoveRel(deltaX: Int16, deltaY: Int16) -> Data {
        var writer = beginInput(length: MoonlightProtocol.mouseMoveRelLength, type: MoonlightInputType.mouseMoveRel)
        writer.i16BE(deltaX)
        writer.i16BE(deltaY)
        return writer.data
    }

    public static func mouseButton(down: Bool, button: UInt8) -> Data {
        let type = down ? MoonlightInputType.mouseButtonDown : MoonlightInputType.mouseButtonUp
        var writer = beginInput(length: MoonlightProtocol.mouseButtonLength, type: type)
        writer.u8(button)
        return writer.data
    }

    /// The amount twice, big-endian, then a zero word; 120 per wheel notch,
    /// positive is up.
    public static func mouseScroll(amount: Int16) -> Data {
        var writer = beginInput(length: MoonlightProtocol.mouseScrollLength, type: MoonlightInputType.mouseScroll)
        writer.i16BE(amount)
        writer.i16BE(amount)
        writer.i16BE(0)
        return writer.data
    }

    /// The keepalive, in the form Wolf captured from a real client: a
    /// four-byte length word of 4 and four zero bytes.
    public static func periodicPing() -> Data {
        var writer = ByteWriter(capacity: MoonlightProtocol.periodicPingLength)
        writer.u16LE(MoonlightProtocol.packetPeriodicPing)
        writer.u16LE(UInt16(MoonlightProtocol.periodicPingLength - MoonlightProtocol.controlHeaderLength))
        writer.u32LE(4)
        writer.u32LE(0)
        return writer.data
    }

    /// The graceful end of a session, reason big-endian.
    public static func termination() -> Data {
        var writer = ByteWriter(capacity: MoonlightProtocol.terminationLength)
        writer.u16LE(MoonlightProtocol.packetTermination)
        writer.u16LE(UInt16(MoonlightProtocol.terminationLength - MoonlightProtocol.controlHeaderLength))
        writer.u32BE(MoonlightProtocol.terminateReasonGraceful)
        return writer.data
    }

    /// The control header and the INPUT_DATA wrapper: the data size counts
    /// from the input type to the end of the message.
    private static func beginInput(length: Int, type: UInt32) -> ByteWriter {
        var writer = ByteWriter(capacity: length)
        writer.u16LE(MoonlightProtocol.packetInputData)
        writer.u16LE(UInt16(length - MoonlightProtocol.controlHeaderLength))
        writer.u32BE(UInt32(length - MoonlightProtocol.controlHeaderLength - 4))
        writer.u32LE(type)
        return writer
    }
}
