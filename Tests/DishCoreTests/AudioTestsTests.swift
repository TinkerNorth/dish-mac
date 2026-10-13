// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import XCTest
@testable import DishCore

/// The test tone sweeps 660 to 880 Hz over 40 windows at 0.35, phase
/// continuous; the mic level is the window's RMS and peak in percent.
final class AudioTestsTests: XCTestCase {

    func testTheToneIsDishAndroidsSweep() {
        XCTAssertEqual(TestTone.windows, 40)
        XCTAssertEqual(TestTone.amplitude, 0.35)
        XCTAssertEqual(TestTone.frequency(at: 0), 660)
        XCTAssertEqual(TestTone.frequency(at: 39), 880)
        XCTAssertEqual(TestTone.frequency(at: 99), 880, "past the end stays at the end")
    }

    func testAWindowIsStereoAtTheAmplitudeAndContinuesThePhase() {
        var phase: Float = 0
        let first = TestTone.window(at: 0, phase: &phase)
        XCTAssertEqual(first.count, 960 * 2)
        XCTAssertEqual(first[0], 0, "the sweep starts at zero crossing")
        XCTAssertEqual(first[2], first[3], "both channels carry the tone")
        XCTAssertEqual(first.map(abs).max() ?? 0, 0.35, accuracy: 0.001)
        XCTAssertGreaterThan(phase, 0)
        let second = TestTone.window(at: 1, phase: &phase)
        XCTAssertNotEqual(second[0], 0, "the next window picks the phase up, it does not restart")
    }

    func testTheMicLevelIsTheWindowsRmsAndPeakInPercent() {
        XCTAssertEqual(MicLevel.of([]), MicLevel(levelPercent: 0, peakPercent: 0))
        XCTAssertEqual(MicLevel.of([Float](repeating: 0, count: 960)), MicLevel(levelPercent: 0, peakPercent: 0))
        XCTAssertEqual(MicLevel.of([0.5, -0.5, 0.5, -0.5]), MicLevel(levelPercent: 50, peakPercent: 50))
        XCTAssertEqual(MicLevel.of([1, 0, 0, 0]), MicLevel(levelPercent: 50, peakPercent: 100))
        XCTAssertEqual(MicLevel.of([3, -3]), MicLevel(levelPercent: 100, peakPercent: 100), "clipped input reads as full scale")
        XCTAssertEqual(MicLevel.meterMs, 8000)
    }
}
