// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// A Steam Controller's two trackpads onto the wire, by the slot's pick: the
// 2015 right pad as the right stick with its click as R3, both pads on the
// one touch surface, the right pad as the cursor with the left as the wheel
// and right button, or nowhere, with the clicks on the extended-buttons word
// wherever nothing else takes them. The decoders hand the router raw pad
// samples; the router owns the 2015 right stick and the touch surface, and
// builds nothing per report.

import Foundation

/// Which trackpads a Direct pad has: none, the 2015 pad's (its right pad is
/// the right stick until picked otherwise), or the 2026 pad's two beside a
/// real right stick.
public enum SteamTrackpads: Equatable, Sendable {
    case none
    case rightStickByDefault
    case twoPads
}

/// A trackpad as its decoder reads it: up-positive, the full int16 range,
/// SDL's shell rotation applied on the 2015 pads.
public struct SteamPadSample: Equatable, Sendable {
    public var active: Bool
    public var x: Int16
    public var y: Int16
    public var clicked: Bool

    public init(active: Bool = false, x: Int16 = 0, y: Int16 = 0, clicked: Bool = false) {
        self.active = active
        self.x = x
        self.y = y
        self.clicked = clicked
    }
}

public struct SteamPads: Equatable, Sendable {
    public var left: SteamPadSample
    public var right: SteamPadSample

    public init(left: SteamPadSample = SteamPadSample(), right: SteamPadSample = SteamPadSample()) {
        self.left = left
        self.right = right
    }
}

/// Mouse mode's wheel: the left pad's vertical travel, one notch per
/// `unitsPerNotch`, the rest carried to the next sample; a lifted pad starts
/// the next swipe fresh.
public struct SteamPadScroll: Equatable, Sendable {
    public static let unitsPerNotch: Int32 = 4096

    private var lastY: Int16?
    private var remainder: Int32 = 0

    public init() {}

    public mutating func advance(_ left: SteamPadSample) -> Int16 {
        guard left.active else {
            self = SteamPadScroll()
            return 0
        }
        guard let origin = lastY else {
            lastY = left.y
            return 0
        }
        remainder += Int32(left.y) - Int32(origin)
        lastY = left.y
        let notches = remainder / Self.unitsPerNotch
        remainder -= notches * Self.unitsPerNotch
        return Int16(clamping: notches * Int32(ProtocolConstants.scrollUnitsPerNotch))
    }
}

/// What the router lands on the touch surface: two finger slots (the lane
/// stamps their wire ids), the pointer frame's buttons and its wheel.
public struct SteamSurface: Equatable, Sendable {
    public var finger0: TouchpadFinger
    public var finger1: TouchpadFinger
    public var leftButton: Bool
    public var rightButton: Bool
    public var scrollV: Int16

    public init(finger0: TouchpadFinger, finger1: TouchpadFinger, leftButton: Bool, rightButton: Bool, scrollV: Int16) {
        self.finger0 = finger0
        self.finger1 = finger1
        self.leftButton = leftButton
        self.rightButton = rightButton
        self.scrollV = scrollV
    }

    /// Nothing on the surface.
    public static let lifted = SteamSurface(finger0: .none, finger1: .none, leftButton: false, rightButton: false, scrollV: 0)
}

/// One report through the router: the XUSB state with the pads' share of it
/// and the surface beside it.
public struct SteamRouted: Equatable, Sendable {
    public let report: GamepadReport
    public let surface: SteamSurface

    public init(report: GamepadReport, surface: SteamSurface) {
        self.report = report
        self.surface = surface
    }
}

private enum SteamSurfaceLayout {
    /// Pad mode's halves: each pad's full range folded onto one side.
    static let halfSurface: Int32 = 16384
    static let leftFingerId: UInt8 = 0
    static let rightFingerId: UInt8 = 1
}

/// The 2015 right pad is the right stick unless the pick says otherwise, so
/// the router owns those axes on that model; the 2026 pad's real stick is
/// the decoder's and untouched here.
public func routeSteamTrackpads(
    pick: TouchpadPick,
    trackpads: SteamTrackpads,
    pads: SteamPads,
    report: GamepadReport,
    scroll: inout SteamPadScroll
) -> SteamRouted {
    let rightPadIsTheStick = trackpads == .rightStickByDefault
    let base = rightPadIsTheStick ? withoutRightStick(report) : report
    switch pick {
    case .stick: return rightPadIsTheStick ? routeAsStick(pads, base) : routeAsOff(pads, base)
    case .pad: return routeAsPad(pads, base)
    case .mouse: return routeAsMouse(pads, base, scroll: &scroll)
    case .off: return routeAsOff(pads, base)
    }
}

private func withoutRightStick(_ report: GamepadReport) -> GamepadReport {
    var centred = report
    centred.rx = 0
    centred.ry = 0
    return centred
}

/// Pads are up-positive and the wire's touch surface is +y down; -(-32768)
/// has no int16, so it clamps.
private func padYToWire(_ y: Int16) -> Int16 {
    Int16(clamping: -Int32(y))
}

private func finger(_ id: UInt8, _ pad: SteamPadSample, x: Int16) -> TouchpadFinger {
    guard pad.active else { return .none }
    return TouchpadFinger(active: true, id: id, x: x, y: padYToWire(pad.y))
}

private func routeAsStick(_ pads: SteamPads, _ report: GamepadReport) -> SteamRouted {
    var routed = report
    routed.rx = pads.right.active ? pads.right.x : 0
    routed.ry = pads.right.active ? pads.right.y : 0
    if pads.right.clicked { routed.buttons |= WireButton.rightThumb.bit }
    if pads.left.clicked { routed.extButtons |= ProtocolConstants.extButtonLeftPadClick }
    return SteamRouted(report: routed, surface: .lifted)
}

private func routeAsPad(_ pads: SteamPads, _ report: GamepadReport) -> SteamRouted {
    let leftX = Int16(clamping: Int32(pads.left.x) / 2 - SteamSurfaceLayout.halfSurface)
    let rightX = Int16(clamping: Int32(pads.right.x) / 2 + SteamSurfaceLayout.halfSurface)
    let surface = SteamSurface(
        finger0: finger(SteamSurfaceLayout.leftFingerId, pads.left, x: leftX),
        finger1: finger(SteamSurfaceLayout.rightFingerId, pads.right, x: rightX),
        leftButton: pads.left.clicked || pads.right.clicked,
        rightButton: false,
        scrollV: 0
    )
    return SteamRouted(report: report, surface: surface)
}

private func routeAsMouse(_ pads: SteamPads, _ report: GamepadReport, scroll: inout SteamPadScroll) -> SteamRouted {
    let surface = SteamSurface(
        finger0: finger(SteamSurfaceLayout.leftFingerId, pads.right, x: pads.right.x),
        finger1: .none,
        leftButton: pads.right.clicked,
        rightButton: pads.left.clicked,
        scrollV: scroll.advance(pads.left)
    )
    return SteamRouted(report: report, surface: surface)
}

private func routeAsOff(_ pads: SteamPads, _ report: GamepadReport) -> SteamRouted {
    var routed = report
    if pads.left.clicked { routed.extButtons |= ProtocolConstants.extButtonLeftPadClick }
    if pads.right.clicked { routed.extButtons |= ProtocolConstants.extButtonRightPadClick }
    return SteamRouted(report: routed, surface: .lifted)
}
