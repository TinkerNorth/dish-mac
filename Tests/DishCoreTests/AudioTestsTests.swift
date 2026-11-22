// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import XCTest
@testable import DishCore

/// The test tone is dish-android's (`SpeakerTestTone.kt`): 660 Hz then
/// 880 Hz, 400 ms each, at 0.35, each note starting at zero phase and fading
/// in and out over 10 ms; the mic level is the window's RMS and peak in
/// percent.
final class AudioTestsTests: XCTestCase {

    private static let window = AudioWire.samplesPerChannel
    private static let note = window * TestTone.windows / 2
    private static let fade = AudioWire.sampleRate * TestTone.fadeMs / 1000

    /// The left channel of the whole tone, window after window.
    private var tone: [Float] {
        (0 ..< TestTone.windows).flatMap { index in
            let window = TestTone.window(at: index)
            return stride(from: 0, to: window.count, by: 2).map { window[$0] }
        }
    }

    func testTheToneIsTwoNotesOf400MsEach() {
        XCTAssertEqual(TestTone.windows, 40)
        XCTAssertEqual(TestTone.amplitude, 0.35)
        XCTAssertEqual(TestTone.fadeMs, 10)
        XCTAssertEqual(TestTone.frequency(atSample: 0), 660)
        XCTAssertEqual(TestTone.frequency(atSample: Self.note - 1), 660)
        XCTAssertEqual(TestTone.frequency(atSample: Self.note), 880)
        XCTAssertEqual(TestTone.frequency(atSample: 2 * Self.note - 1), 880)
    }

    func testAWindowIsStereoWithTheToneOnBothChannels() {
        let window = TestTone.window(at: 10)
        XCTAssertEqual(window.count, Self.window * 2)
        for frame in 0 ..< Self.window {
            XCTAssertEqual(window[2 * frame], window[2 * frame + 1])
        }
    }

    func testEachNoteStartsAtZeroAndFadesInOver10Ms() {
        let samples = tone
        for start in [0, Self.note] {
            XCTAssertEqual(samples[start], 0, "a note starts at zero phase and zero gain")
            let early = samples[start ..< start + Self.fade / 2].map(abs).max() ?? 0
            XCTAssertLessThan(early, TestTone.amplitude * 0.51, "half way into the fade, half the gain at most")
        }
    }

    func testEachNoteReachesTheAmplitudeBetweenItsFades() {
        let samples = tone
        for start in [0, Self.note] {
            let body = samples[start + Self.fade ..< start + Self.note - Self.fade].map(abs).max() ?? 0
            XCTAssertEqual(body, TestTone.amplitude, accuracy: 0.001)
        }
    }

    func testEachNoteFadesOutToSilence() {
        let samples = tone
        for end in [Self.note - 1, 2 * Self.note - 1] {
            XCTAssertEqual(samples[end], 0, accuracy: 0.0001, "the last sample of a note is silent")
            let late = samples[end - Self.fade / 2 ... end].map(abs).max() ?? 0
            XCTAssertLessThan(late, TestTone.amplitude * 0.51)
        }
    }

    func testTheSecondNoteIsHigherThanTheFirst() {
        let samples = tone
        let middle = Self.note / 2
        let firstCrossings = zeroCrossings(Array(samples[middle ..< middle + Self.window]))
        let secondCrossings = zeroCrossings(Array(samples[Self.note + middle ..< Self.note + middle + Self.window]))
        XCTAssertEqual(firstCrossings, 26, accuracy: 1, "660 Hz crosses zero twice a cycle, 13.2 cycles in 20 ms")
        XCTAssertEqual(secondCrossings, 35, accuracy: 1, "880 Hz, 17.6 cycles in 20 ms")
    }

    private func zeroCrossings(_ samples: [Float]) -> Int {
        zip(samples, samples.dropFirst()).filter { ($0 < 0) != ($1 < 0) }.count
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
