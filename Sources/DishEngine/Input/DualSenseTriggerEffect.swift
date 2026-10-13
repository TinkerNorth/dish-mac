// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Foundation

/// A DualSense trigger-effect block as the game wrote it, decoded into the
/// shapes GameController's adaptive-trigger API can play. The block is the
/// mode byte plus ten parameters, in the firmware's vocabulary; this is the
/// one place that vocabulary is read.
///
/// Positions are the trigger's ten discrete zones mapped onto 0...1;
/// strengths and amplitudes are the firmware's eight steps mapped onto
/// 0...1; a frequency is the firmware's byte over 255. A mode the API cannot
/// express plays its nearest shape, and an unknown mode resets the trigger.
enum DualSenseTriggerEffect: Equatable {
    case off
    case feedback(startPosition: Float, strength: Float)
    case positionalFeedback(strengths: [Float])
    case weapon(startPosition: Float, endPosition: Float, strength: Float)
    case vibration(startPosition: Float, amplitude: Float, frequency: Float)
    case positionalVibration(amplitudes: [Float], frequency: Float)

    static let zoneCount = 10
    private static let lastZone = Float(zoneCount - 1)
    private static let steps: Float = 8

    /// The firmware's mode bytes.
    enum Mode: UInt8 {
        case off = 0x00
        case legacyFeedback = 0x01
        case legacyWeapon = 0x02
        case reset = 0x05
        case feedback = 0x21
        case bow = 0x22
        case galloping = 0x23
        case weapon = 0x25
        case vibration = 0x26
        case machine = 0x27
    }

    /// Decode one 11-byte block. A short block, or an unknown mode, is off.
    static func decode(_ block: [UInt8]) -> DualSenseTriggerEffect {
        guard block.count >= 11, let mode = Mode(rawValue: block[0]) else { return .off }
        let params = Array(block[1 ..< 11])
        switch mode {
        case .off, .reset, .galloping: return .off
        case .legacyFeedback: return .feedback(startPosition: byteFraction(params[0]), strength: byteFraction(params[1]))
        case .legacyWeapon:
            return .weapon(startPosition: byteFraction(params[0]), endPosition: byteFraction(params[1]), strength: byteFraction(params[2]))
        case .feedback: return .positionalFeedback(strengths: zoneValues(params))
        case .weapon:
            let zones = zoneRange(params)
            return .weapon(startPosition: zones.start, endPosition: zones.end, strength: stepFraction(params[2]))
        case .bow:
            let zones = zoneRange(params)
            return .weapon(startPosition: zones.start, endPosition: zones.end, strength: stepFraction(params[2] & 0x07))
        case .vibration: return .positionalVibration(amplitudes: zoneValues(params), frequency: byteFraction(params[8]))
        case .machine: return machine(params)
        }
    }

    /// Bytes 0-1 are the active zones (u16 LE, bit i = zone i); bytes 2-5
    /// hold a 3-bit step per zone (u32 LE, zone i at bits 3i..3i+2); an
    /// inactive zone reads 0.
    private static func zoneValues(_ params: [UInt8]) -> [Float] {
        let active = UInt16(params[0]) | UInt16(params[1]) << 8
        let packed = UInt32(params[2]) | UInt32(params[3]) << 8 | UInt32(params[4]) << 16 | UInt32(params[5]) << 24
        return (0 ..< zoneCount).map { zone in
            guard active & (1 << UInt16(zone)) != 0 else { return 0 }
            return stepFraction(UInt8((packed >> UInt32(3 * zone)) & 0x07))
        }
    }

    /// Bytes 0-1 name two zones, the start and the end of the effect.
    private static func zoneRange(_ params: [UInt8]) -> (start: Float, end: Float) {
        let active = UInt16(params[0]) | UInt16(params[1]) << 8
        let zones = (0 ..< zoneCount).filter { active & (1 << UInt16($0)) != 0 }
        let start = zones.first ?? 0
        let end = zones.last ?? start
        return (zoneFraction(start), zoneFraction(end))
    }

    /// The machine effect: two amplitudes in one byte (A in the low bits, B
    /// in the high), a frequency byte, and a period this API has no knob
    /// for. Plays amplitude A across the effect's zones.
    private static func machine(_ params: [UInt8]) -> DualSenseTriggerEffect {
        let active = UInt16(params[0]) | UInt16(params[1]) << 8
        let amplitude = stepFraction(params[2] & 0x07)
        let amplitudes = (0 ..< zoneCount).map { active & (1 << UInt16($0)) != 0 ? amplitude : 0 }
        return .positionalVibration(amplitudes: amplitudes, frequency: byteFraction(params[3]))
    }

    /// A stored step 0...7 is the firmware's strength 1...8.
    private static func stepFraction(_ stored: UInt8) -> Float {
        Float(min(stored, 7) + 1) / steps
    }

    private static func zoneFraction(_ zone: Int) -> Float {
        Float(zone) / lastZone
    }

    private static func byteFraction(_ byte: UInt8) -> Float {
        Float(byte) / 255
    }
}
