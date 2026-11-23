// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// The inspector's audio tests, as pure math: the test tone the pad's speaker
// and its haptics lanes play (dish-android's `SpeakerTestTone`, so a pad
// sounds the same on every client) and the level the microphone meter shows
// of one captured window.

import Foundation

public enum TestTone {
    /// 660 Hz for the first half of the tone's 40 windows (800 ms), 880 Hz
    /// for the second.
    public static let firstHz: Float = 660
    public static let secondHz: Float = 880
    public static let windows = 40
    public static let amplitude: Float = 0.35
    /// Each note fades in and out over this long, so neither starts or stops
    /// with a click.
    public static let fadeMs = 10

    private static let samplesPerNote = AudioWire.samplesPerChannel * windows / 2
    private static let fadeSamples = AudioWire.sampleRate * fadeMs / 1000

    /// The note sample `n` of the tone belongs to.
    public static func frequency(atSample sample: Int) -> Float {
        sample < samplesPerNote ? firstHz : secondHz
    }

    /// One 20 ms stereo window of the tone, interleaved. Each note starts at
    /// zero phase, so a window needs nothing from the one before.
    public static func window(at index: Int) -> [Float] {
        var out = [Float](repeating: 0, count: AudioWire.samplesPerChannel * AudioWire.speakerChannels)
        for frame in 0 ..< AudioWire.samplesPerChannel {
            let value = sample(index * AudioWire.samplesPerChannel + frame)
            out[frame * 2] = value
            out[frame * 2 + 1] = value
        }
        return out
    }

    /// The tone's sample `n`: the note's sine under its fade envelope.
    private static func sample(_ sample: Int) -> Float {
        let inNote = sample % samplesPerNote
        let fromEdge = min(inNote, samplesPerNote - 1 - inNote)
        let envelope = min(1, Double(fromEdge) / Double(fadeSamples))
        let phase = 2 * Double.pi * Double(frequency(atSample: sample)) * Double(inNote) / Double(AudioWire.sampleRate)
        return Float(sin(phase) * Double(amplitude) * envelope)
    }
}

/// What the microphone meter shows of one window: the level (RMS) and the
/// peak, each in whole percent of full scale.
public struct MicLevel: Hashable, Sendable {
    public var levelPercent: Int
    public var peakPercent: Int

    public init(levelPercent: Int, peakPercent: Int) {
        self.levelPercent = levelPercent
        self.peakPercent = peakPercent
    }

    /// The meter listens this long, then stops on its own.
    public static let meterMs: Int64 = 8000

    public static func of(_ samples: [Float]) -> MicLevel {
        guard !samples.isEmpty else { return MicLevel(levelPercent: 0, peakPercent: 0) }
        var sumOfSquares: Float = 0
        var peak: Float = 0
        for sample in samples {
            sumOfSquares += sample * sample
            peak = max(peak, abs(sample))
        }
        let rms = (sumOfSquares / Float(samples.count)).squareRoot()
        return MicLevel(levelPercent: percent(rms), peakPercent: percent(peak))
    }

    private static func percent(_ fraction: Float) -> Int {
        Int((min(max(fraction, 0), 1) * 100).rounded())
    }
}
