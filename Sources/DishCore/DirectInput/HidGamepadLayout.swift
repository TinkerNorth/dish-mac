// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// A generic HID gamepad's field map, distilled once from its report
// descriptor (`HidDescriptor.swift`), and the bit-exact decode of each report
// over it, ported from the desktops' `UsbHidLayout.h`. The decode reads the
// caller's buffer in place and builds no collection. HID's Y axes are
// down-positive and the wire's are up-positive, so the Y axes are inverted.

import Foundation

/// Where one value lives in the report payload, and its declared range.
public struct HidField: Equatable, Sendable {
    public let bitOffset: UInt16
    public let bitSize: UInt8
    public let logicalMin: Int32
    public let logicalMax: Int32

    public init(bitOffset: UInt16, bitSize: UInt8, logicalMin: Int32, logicalMax: Int32) {
        self.bitOffset = bitOffset
        self.bitSize = bitSize
        self.logicalMin = logicalMin
        self.logicalMax = logicalMax
    }

    /// A three-state axis is a direction pad the device declared as an axis.
    var isDirection: Bool {
        Int64(logicalMax) - Int64(logicalMin) == 2
    }
}

public struct HidGamepadLayout: Equatable, Sendable {
    /// 0 when the device sends no report-id prefix byte.
    public var reportId: UInt8 = 0
    public var lx: HidField?
    public var ly: HidField?
    public var rx: HidField?
    public var ry: HidField?
    public var lt: HidField?
    public var rt: HidField?
    public var hat: HidField?
    public var buttonBitOffset: UInt16 = 0
    public var buttonCount: UInt8 = 0
    /// From the model table, never from the descriptor.
    public var order = HidButtonOrder.western

    public init() {}

    var isGamepadLike: Bool {
        let steers = lx != nil || ly != nil || hat != nil
        let presses = buttonCount > 0
        return steers || presses
    }
}

enum HidScale {
    static let axisMax: Int64 = 32767
    static let triggerMax: Int64 = 255
    static let fullTrigger: UInt8 = 255
    static let maxBitsPerValue: UInt8 = 32
}

/// Up to 32 bits little-endian from `bitOffset`; bits past the end read 0.
func extractBits(_ payload: UnsafeBufferPointer<UInt8>, bitOffset: UInt32, bits: UInt8) -> UInt32 {
    var value: UInt32 = 0
    let width = min(bits, HidScale.maxBitsPerValue)
    for index in 0 ..< UInt32(width) {
        let bit = bitOffset + index
        let byte = Int(bit >> 3)
        guard byte < payload.count else { break }
        let set = (payload[byte] >> UInt8(bit & 7)) & 1 != 0
        if set { value |= 1 << index }
    }
    return value
}

/// A raw value is signed only when the declared minimum is negative.
func toSigned(_ raw: UInt32, bits: UInt8, logicalMin: Int32) -> Int32 {
    let signedField = logicalMin < 0 && bits > 0 && bits < HidScale.maxBitsPerValue
    guard signedField else { return Int32(bitPattern: raw) }
    let signBit = UInt32(1) << (bits - 1)
    let negative = raw & signBit != 0
    guard negative else { return Int32(bitPattern: raw) }
    let signFill = ~((UInt32(1) << bits) - 1)
    return Int32(bitPattern: raw | signFill)
}

/// The bounds are the device's own 32-bit words, so the arithmetic runs in
/// 64 bits.
func scaleHidAxis(_ raw: UInt32, _ field: HidField) -> Int16 {
    let value = Int64(toSigned(raw, bits: field.bitSize, logicalMin: field.logicalMin))
    let low = Int64(field.logicalMin)
    let high = Int64(field.logicalMax)
    let center = (low + high) / 2
    let half = (high - low) / 2
    guard half > 0 else { return 0 }
    return Int16(clamping: (value - center) * HidScale.axisMax / half)
}

/// Down-positive HID onto the up-positive wire, saturating: Int16.min has no
/// negation.
func invertedHidAxis(_ raw: UInt32, _ field: HidField) -> Int16 {
    let downPositive = scaleHidAxis(raw, field)
    return Int16(clamping: -Int32(downPositive))
}

func scaleHidTrigger(_ raw: UInt32, _ field: HidField) -> UInt8 {
    let value = Int64(toSigned(raw, bits: field.bitSize, logicalMin: field.logicalMin))
    let low = Int64(field.logicalMin)
    let span = Int64(field.logicalMax) - low
    guard span > 0 else { return 0 }
    return UInt8(clamping: (value - low) * HidScale.triggerMax / span)
}

/// The low end of a three-state axis presses `low`, the high end `high`.
func directionButtons(_ raw: UInt32, _ field: HidField, low: WireButton, high: WireButton) -> WireButtonWord {
    let step = Int64(toSigned(raw, bits: field.bitSize, logicalMin: field.logicalMin)) - Int64(field.logicalMin)
    switch step {
    case 0: return [low]
    case 2: return [high]
    default: return []
    }
}

func hatButtons(_ raw: UInt32, _ field: HidField) -> WireButtonWord {
    let direction = Int64(raw) - Int64(field.logicalMin)
    let range = Int64(field.logicalMax) - Int64(field.logicalMin)
    let declared = direction >= 0 && direction <= range
    let named = direction < Int64(hatDirections.count)
    guard declared, named else { return [] }
    return hatDirections[Int(direction)]
}

// MARK: - Decoding a report

public extension HidGamepadLayout {
    /// Nil when the report carries another report id. Bit offsets are
    /// relative to the payload after the id byte when there is one.
    func decode(_ report: UnsafeBufferPointer<UInt8>) -> GamepadReport? {
        guard reportId != 0 else { return decodePayload(report) }
        guard report.count >= 1, report[0] == reportId else { return nil }
        return decodePayload(UnsafeBufferPointer(rebasing: report[1...]))
    }
}

extension HidGamepadLayout {
    private func read(_ field: HidField, _ payload: UnsafeBufferPointer<UInt8>) -> UInt32 {
        extractBits(payload, bitOffset: UInt32(field.bitOffset), bits: field.bitSize)
    }

    /// Only the left stick's axes are read as a d-pad when three-state.
    private func analog(_ field: HidField?) -> HidField? {
        field.flatMap { $0.isDirection ? nil : $0 }
    }

    private func axis(_ field: HidField?, _ payload: UnsafeBufferPointer<UInt8>) -> Int16 {
        guard let field else { return 0 }
        return scaleHidAxis(read(field, payload), field)
    }

    private func invertedAxis(_ field: HidField?, _ payload: UnsafeBufferPointer<UInt8>) -> Int16 {
        guard let field else { return 0 }
        return invertedHidAxis(read(field, payload), field)
    }

    private func trigger(_ field: HidField?, _ payload: UnsafeBufferPointer<UInt8>) -> UInt8 {
        guard let field else { return 0 }
        return scaleHidTrigger(read(field, payload), field)
    }

    private func direction(_ field: HidField?, _ payload: UnsafeBufferPointer<UInt8>, low: WireButton, high: WireButton) -> UInt16 {
        guard let field, field.isDirection else { return 0 }
        return directionButtons(read(field, payload), field, low: low, high: high).rawValue
    }

    private func hatWord(_ payload: UnsafeBufferPointer<UInt8>) -> UInt16 {
        guard let hat else { return 0 }
        return hatButtons(read(hat, payload), hat).rawValue
    }

    private func buttonHeld(_ index: Int, _ payload: UnsafeBufferPointer<UInt8>) -> Bool {
        let bit = UInt32(buttonBitOffset) + UInt32(index)
        return extractBits(payload, bitOffset: bit, bits: 1) != 0
    }

    /// The declared buttons onto the wire. A digital trigger is the whole
    /// truth about its trigger: an analog usage beside it only echoes it.
    private func applyButtons(_ payload: UnsafeBufferPointer<UInt8>, to state: inout GamepadReport) {
        let map = buttonOrderMap(order)
        var word = WireButtonWord()
        var leftPulled = false
        var rightPulled = false
        for index in 0 ..< Int(buttonCount) where buttonHeld(index, payload) {
            if index == map.triggers?.left {
                leftPulled = true
            } else if index == map.triggers?.right {
                rightPulled = true
            } else if let button = map.button(at: index) {
                word.insert(button)
            }
        }
        state.buttons |= word.rawValue
        guard map.triggers != nil else { return }
        state.lt = leftPulled ? HidScale.fullTrigger : 0
        state.rt = rightPulled ? HidScale.fullTrigger : 0
    }

    private func decodePayload(_ payload: UnsafeBufferPointer<UInt8>) -> GamepadReport {
        let horizontal = direction(lx, payload, low: .dpadLeft, high: .dpadRight)
        let vertical = direction(ly, payload, low: .dpadUp, high: .dpadDown)
        var state = GamepadReport(
            buttons: horizontal | vertical | hatWord(payload),
            lt: trigger(lt, payload),
            rt: trigger(rt, payload),
            lx: axis(analog(lx), payload),
            ly: invertedAxis(analog(ly), payload),
            rx: axis(rx, payload),
            ry: invertedAxis(ry, payload)
        )
        applyButtons(payload, to: &state)
        return state
    }
}
