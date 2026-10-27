// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// A generic HID pad read through its stored remap. The decode reads the
// declared sources (`HidRawState`: each declared button's bit, the d-pad,
// the six axes), and a fixed table built once from the remap maps them to
// the wire. Neither allocates, so the reader's thread applies the table to
// every report; the table is rebuilt only when the stored remap changes.

import Foundation

/// A pad's six declared axes, centred, in HID's sign (Y down-positive), by
/// `RemapAxis` slot.
public struct HidRawAxes: Equatable, Sendable {
    public var lx: Int16 = 0
    public var ly: Int16 = 0
    public var lt: Int16 = 0
    public var rx: Int16 = 0
    public var ry: Int16 = 0
    public var rt: Int16 = 0

    public init() {}

    /// 0 for a slot past the six.
    public subscript(slot: Int) -> Int16 {
        switch slot {
        case RemapAxis.leftX: lx
        case RemapAxis.leftY: ly
        case RemapAxis.leftTrigger: lt
        case RemapAxis.rightX: rx
        case RemapAxis.rightY: ry
        case RemapAxis.rightTrigger: rt
        default: 0
        }
    }
}

/// What one report declared, before any mapping onto the wire.
public struct HidRawState: Equatable, Sendable {
    /// Declared button `i` held is bit `i`.
    public var buttons: UInt32 = 0
    /// The hat's wire bits, or those of the three-state axes declared instead of one.
    public var dpad: UInt16 = 0
    public var axes = HidRawAxes()
    /// The trigger fields read as triggers, 0...255, as the plain decode reads them.
    public var leftLevel: UInt8 = 0
    public var rightLevel: UInt8 = 0

    public init() {}
}

public enum HidRemapLimits {
    /// The descriptor parser keeps the first 16 buttons.
    public static let buttons = 16
}

public extension HidGamepadLayout {
    /// The declared sources, nil when the report carries another report id.
    func decodeRaw(_ report: UnsafeBufferPointer<UInt8>) -> HidRawState? {
        guard reportId != 0 else { return rawPayload(report) }
        guard report.count >= 1, report[0] == reportId else { return nil }
        return rawPayload(UnsafeBufferPointer(rebasing: report[1...]))
    }
}

extension HidGamepadLayout {
    private func rawValue(_ field: HidField, _ payload: UnsafeBufferPointer<UInt8>) -> UInt32 {
        extractBits(payload, bitOffset: UInt32(field.bitOffset), bits: field.bitSize)
    }

    private func rawAxis(_ field: HidField?, _ payload: UnsafeBufferPointer<UInt8>) -> Int16 {
        guard let field, !field.isDirection else { return 0 }
        return scaleHidAxis(rawValue(field, payload), field)
    }

    private func rawLevel(_ field: HidField?, _ payload: UnsafeBufferPointer<UInt8>) -> UInt8 {
        guard let field else { return 0 }
        return scaleHidTrigger(rawValue(field, payload), field)
    }

    private func rawDirection(_ field: HidField?, _ payload: UnsafeBufferPointer<UInt8>, low: WireButton, high: WireButton) -> UInt16 {
        guard let field, field.isDirection else { return 0 }
        return directionButtons(rawValue(field, payload), field, low: low, high: high).rawValue
    }

    private func rawDpad(_ payload: UnsafeBufferPointer<UInt8>) -> UInt16 {
        let hatWord = hat.map { hatButtons(rawValue($0, payload), $0).rawValue } ?? 0
        let horizontal = rawDirection(lx, payload, low: .dpadLeft, high: .dpadRight)
        let vertical = rawDirection(ly, payload, low: .dpadUp, high: .dpadDown)
        return hatWord | horizontal | vertical
    }

    private func rawButtons(_ payload: UnsafeBufferPointer<UInt8>) -> UInt32 {
        let count = min(Int(buttonCount), HidRemapLimits.buttons)
        guard count > 0 else { return 0 }
        return extractBits(payload, bitOffset: UInt32(buttonBitOffset), bits: UInt8(count))
    }

    private func rawPayload(_ payload: UnsafeBufferPointer<UInt8>) -> HidRawState {
        var state = HidRawState()
        state.buttons = rawButtons(payload)
        state.dpad = rawDpad(payload)
        state.axes.lx = rawAxis(lx, payload)
        state.axes.ly = rawAxis(ly, payload)
        state.axes.lt = rawAxis(lt, payload)
        state.axes.rx = rawAxis(rx, payload)
        state.axes.ry = rawAxis(ry, payload)
        state.axes.rt = rawAxis(rt, payload)
        state.leftLevel = rawLevel(lt, payload)
        state.rightLevel = rawLevel(rt, payload)
        return state
    }
}

// MARK: - The table

/// A remap as the hot path reads it: plain words, no collection.
public struct HidRemapTable: Equatable, Sendable {
    /// Each declared button's wire bits.
    let buttonBits: SIMD16<UInt16>
    let hatDrivesDpad: Bool
    let leftTrigger: TriggerSource
    let rightTrigger: TriggerSource
    let leftX: Int
    let leftY: Int
    let rightX: Int
    let rightY: Int
    let invertLeftY: Bool
    let invertRightY: Bool

    public init(remap: JoystickRemap) {
        var bits = SIMD16<UInt16>()
        for which in RemapButton.allCases {
            addBit(&bits, index: remap.button(which), wire: which.wire)
        }
        addBit(&bits, index: remap.guide, wire: .guide)
        buttonBits = bits
        hatDrivesDpad = remap.hatIndex == RemapDefaults.hat
        leftTrigger = remap.leftTrigger
        rightTrigger = remap.rightTrigger
        leftX = remap.leftStickX
        leftY = remap.leftStickY
        rightX = remap.rightStickX
        rightY = remap.rightStickY
        invertLeftY = remap.invertLeftY
        invertRightY = remap.invertRightY
    }

    public func apply(_ raw: HidRawState) -> GamepadReport {
        GamepadReport(
            buttons: wireButtons(raw),
            lt: level(leftTrigger, raw),
            rt: level(rightTrigger, raw),
            lx: raw.axes[leftX],
            ly: stickY(raw.axes[leftY], inverted: invertLeftY),
            rx: raw.axes[rightX],
            ry: stickY(raw.axes[rightY], inverted: invertRightY)
        )
    }

    private func wireButtons(_ raw: HidRawState) -> UInt16 {
        var word = hatDrivesDpad ? raw.dpad : 0
        for index in 0 ..< HidRemapLimits.buttons where held(raw, index) {
            word |= buttonBits[index]
        }
        return word
    }

    private func level(_ source: TriggerSource, _ raw: HidRawState) -> UInt8 {
        switch source.kind {
        case .button: held(raw, source.index) ? HidScale.fullTrigger : 0
        case .axis: axisLevel(source.index, raw)
        }
    }

    /// A trigger field keeps its own scaling; a stick axis gives its positive half, as the desktops' `triggerFromAxis`.
    private func axisLevel(_ slot: Int, _ raw: HidRawState) -> UInt8 {
        switch slot {
        case RemapAxis.leftTrigger: raw.leftLevel
        case RemapAxis.rightTrigger: raw.rightLevel
        default: UInt8(clamping: max(Int(raw.axes[slot]), 0) * Int(HidScale.triggerMax) / Int(HidScale.axisMax))
        }
    }
}

private func addBit(_ bits: inout SIMD16<UInt16>, index: Int, wire: WireButton) {
    guard index >= 0, index < HidRemapLimits.buttons else { return }
    bits[index] |= wire.bit
}

private func held(_ raw: HidRawState, _ index: Int) -> Bool {
    guard index >= 0, index < HidRemapLimits.buttons else { return false }
    return raw.buttons & (UInt32(1) << UInt32(index)) != 0
}

/// Down-positive HID onto the up-positive wire when inverted, saturating.
private func stickY(_ value: Int16, inverted: Bool) -> Int16 {
    inverted ? Int16(clamping: -Int32(value)) : value
}

// MARK: - Capturing a change

/// The change the walk assigns: a button newly held since the last report,
/// else the d-pad newly moved off centre, else an axis crossing out past the
/// threshold from where it rested when the walk began, so a control still
/// held from the step before, or let go, is not a fresh choice.
public func rawCapture(rest: HidRawState, previous: HidRawState, now: HidRawState) -> RawCapture? {
    let pressed = now.buttons & ~previous.buttons
    if pressed != 0 { return RawCapture(kind: .button, index: pressed.trailingZeroBitCount) }
    let newDirections = now.dpad & ~previous.dpad
    if captureHatPasses(newDirections) { return RawCapture(kind: .hat, index: RemapDefaults.hat) }
    return axisCapture(rest: rest, previous: previous, now: now)
}

private func axisCapture(rest: HidRawState, previous: HidRawState, now: HidRawState) -> RawCapture? {
    for slot in 0 ..< RemapAxis.count {
        let travel = Int(now.axes[slot]) - Int(rest.axes[slot])
        let travelled = Int(previous.axes[slot]) - Int(rest.axes[slot])
        let crossedOut = captureAxisPasses(travel) && !captureAxisPasses(travelled)
        if crossedOut { return RawCapture(kind: .axis, index: slot, travel: travel) }
    }
    return nil
}
