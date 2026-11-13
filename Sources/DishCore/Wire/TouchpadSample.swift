// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

/// One finger slot of a touchpad sample: whether it is down, its monotonic
/// tracking id, and its normalised int16 position (contract §0x000C).
public struct TouchpadFinger: Equatable, Sendable {
    public var active: Bool
    public var id: UInt8
    public var x: Int16
    public var y: Int16

    public init(active: Bool, id: UInt8, x: Int16, y: Int16) {
        self.active = active
        self.id = id
        self.x = x
        self.y = y
    }

    /// A lifted finger with no id: what an absent slot carries.
    public static let none = TouchpadFinger(active: false, id: 0, x: 0, y: 0)
}

/// A touchpad sample as MSG_TOUCHPAD carries it: two finger slots and the
/// clickable-pad button. The sender stamps `eventTimeMs` separately, since the
/// stamp is taken at publish time rather than being part of the sample.
public struct TouchpadSample: Equatable, Sendable {
    public var finger0: TouchpadFinger
    public var finger1: TouchpadFinger
    /// The pad's click, the POINTER frame's left button.
    public var buttonPressed: Bool
    /// The POINTER frame's right button: a Steam Controller's left pad
    /// clicked in mouse mode. Nothing on the 16-byte frame.
    public var rightButtonPressed: Bool

    public init(finger0: TouchpadFinger, finger1: TouchpadFinger, buttonPressed: Bool, rightButtonPressed: Bool = false) {
        self.finger0 = finger0
        self.finger1 = finger1
        self.buttonPressed = buttonPressed
        self.rightButtonPressed = rightButtonPressed
    }
}
