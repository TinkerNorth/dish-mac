// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import XCTest
@testable import DishEngine

/// The one reader of the DualSense trigger-effect vocabulary, one case per
/// mode byte the firmware knows.
final class DualSenseTriggerEffectTests: XCTestCase {

    private func block(_ mode: UInt8, _ params: [UInt8]) -> [UInt8] {
        [mode] + params + [UInt8](repeating: 0, count: 10 - params.count)
    }

    func testOffResetAndUnknownModesResetTheTrigger() {
        XCTAssertEqual(DualSenseTriggerEffect.decode(block(0x00, [])), .off)
        XCTAssertEqual(DualSenseTriggerEffect.decode(block(0x05, [1, 2, 3])), .off)
        XCTAssertEqual(DualSenseTriggerEffect.decode(block(0x7E, [1, 2, 3])), .off, "a mode this reader does not know")
        XCTAssertEqual(DualSenseTriggerEffect.decode(block(0x23, [1, 2, 3])), .off, "galloping has no shape in the API")
    }

    func testAShortBlockIsOff() {
        XCTAssertEqual(DualSenseTriggerEffect.decode([0x21, 0xFF]), .off)
        XCTAssertEqual(DualSenseTriggerEffect.decode([]), .off)
    }

    func testTheLegacyModesScaleTheirBytes() {
        XCTAssertEqual(
            DualSenseTriggerEffect.decode(block(0x01, [51, 255])),
            .feedback(startPosition: 0.2, strength: 1)
        )
        XCTAssertEqual(
            DualSenseTriggerEffect.decode(block(0x02, [0, 255, 102])),
            .weapon(startPosition: 0, endPosition: 1, strength: 0.4)
        )
    }

    func testPositionalFeedbackReadsTheActiveZonesAndTheirSteps() {
        // Zones 0 and 9 active; zone 0 at step 7 (full), zone 9 at step 3.
        let active: UInt16 = 0b0000_0010_0000_0001
        let forces: UInt32 = 7 | (3 << 27)
        let params: [UInt8] = [
            UInt8(active & 0xFF), UInt8(active >> 8),
            UInt8(forces & 0xFF), UInt8((forces >> 8) & 0xFF), UInt8((forces >> 16) & 0xFF), UInt8(forces >> 24)
        ]
        let decoded = DualSenseTriggerEffect.decode(block(0x21, params))
        guard case let .positionalFeedback(strengths) = decoded else { return XCTFail("\(decoded)") }
        XCTAssertEqual(strengths.count, 10)
        XCTAssertEqual(strengths[0], 1)
        XCTAssertEqual(strengths[9], 0.5)
        XCTAssertEqual(strengths[1 ... 8].reduce(0, +), 0, "inactive zones read 0")
    }

    func testWeaponReadsItsTwoZonesAndStrength() {
        let zones: UInt16 = (1 << 2) | (1 << 7)
        let decoded = DualSenseTriggerEffect.decode(block(0x25, [UInt8(zones & 0xFF), UInt8(zones >> 8), 7]))
        XCTAssertEqual(decoded, .weapon(startPosition: 2 / 9, endPosition: 7 / 9, strength: 1))
    }

    func testBowPlaysAsAWeaponWithItsLowStrengthBits() {
        let zones: UInt16 = (1 << 1) | (1 << 4)
        let strengthAndSnap: UInt8 = (5 << 3) | 1
        let decoded = DualSenseTriggerEffect.decode(block(0x22, [UInt8(zones & 0xFF), UInt8(zones >> 8), strengthAndSnap]))
        XCTAssertEqual(decoded, .weapon(startPosition: 1 / 9, endPosition: 4 / 9, strength: 0.25))
    }

    func testPositionalVibrationReadsAmplitudesAndFrequency() {
        let active: UInt16 = 1 << 3
        let amplitudes: UInt32 = 4 << 9
        var params: [UInt8] = [
            UInt8(active & 0xFF), UInt8(active >> 8),
            UInt8(amplitudes & 0xFF), UInt8((amplitudes >> 8) & 0xFF), UInt8((amplitudes >> 16) & 0xFF), UInt8(amplitudes >> 24),
            0, 0
        ]
        params.append(51) // frequency byte at parameter 8
        let decoded = DualSenseTriggerEffect.decode(block(0x26, params))
        guard case let .positionalVibration(values, frequency) = decoded else { return XCTFail("\(decoded)") }
        XCTAssertEqual(values[3], 5 / 8)
        XCTAssertEqual(values.filter { $0 != 0 }.count, 1)
        XCTAssertEqual(frequency, 0.2)
    }

    func testMachinePlaysItsFirstAmplitudeAcrossItsZones() {
        let zones: UInt16 = (1 << 2) | (1 << 5)
        let amplitudes: UInt8 = (2 << 3) | 7
        let decoded = DualSenseTriggerEffect.decode(block(0x27, [UInt8(zones & 0xFF), UInt8(zones >> 8), amplitudes, 255]))
        guard case let .positionalVibration(values, frequency) = decoded else { return XCTFail("\(decoded)") }
        XCTAssertEqual(values[2], 1)
        XCTAssertEqual(values[5], 1)
        XCTAssertEqual(values.filter { $0 != 0 }.count, 2)
        XCTAssertEqual(frequency, 1)
    }

    func testAStepBeyondTheFirmwaresRangeIsClampedToFull() {
        let decoded = DualSenseTriggerEffect.decode(block(0x25, [0x01, 0x00, 0xFF]))
        XCTAssertEqual(decoded, .weapon(startPosition: 0, endPosition: 0, strength: 1))
    }
}
