// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

/// One full-state gamepad snapshot in the XUSB layout MSG_INPUT carries:
/// the 16-bit button word, the two analog triggers and the four stick axes.
/// A report is never a delta.
public struct GamepadReport: Equatable, Sendable {
    public var buttons: UInt16
    public var lt: UInt8
    public var rt: UInt8
    public var lx: Int16
    public var ly: Int16
    public var rx: Int16
    public var ry: Int16

    public init(
        buttons: UInt16 = 0,
        lt: UInt8 = 0,
        rt: UInt8 = 0,
        lx: Int16 = 0,
        ly: Int16 = 0,
        rx: Int16 = 0,
        ry: Int16 = 0
    ) {
        self.buttons = buttons
        self.lt = lt
        self.rt = rt
        self.lx = lx
        self.ly = ly
        self.rx = rx
        self.ry = ry
    }

    /// Every button up, every axis centred: what a release-all sends.
    public static let released = GamepadReport()
}
