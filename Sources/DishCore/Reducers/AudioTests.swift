// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// The inspector's two audio tests, as pure math: the test tone the pad's
// speaker plays (dish-android's, so a pad sounds the same on either client)
// and the level the microphone meter shows of one captured window.

import Foundation

public enum TestTone {
    /// The tone sweeps from 660 Hz to 880 Hz over its 40 windows (800 ms).
    public static let startHz: Float = 660
    public static let endHz: Float = 880
    public static let windows = 40
    public static let amplitude: Float = 0.35

    /// The frequency of window `index`, rising linearly across the sweep.
    public static func frequency(at index: Int) -> Float {
        guard windows > 1 else { return startHz }
        let fraction = Float(min(max(index, 0), windows - 1)) / Float(windows - 1)
        return startHz + (endHz - startHz) * fraction
    }

    /// One 20 ms stereo window of the tone, interleaved, phase continuous
    /// from `phase` (in radians), which the caller carries to the next.
    public static func window(at index: Int, phase: inout Float) -> [Float] {
        let hz = frequency(at: index)
        let step = 2 * Float.pi * hz / Float(AudioWire.sampleRate)
        var out = [Float](repeating: 0, count: AudioWire.samplesPerChannel * AudioWire.speakerChannels)
        for frame in 0 ..< AudioWire.samplesPerChannel {
            let value = amplitude * sin(phase)
            out[frame * 2] = value
            out[frame * 2 + 1] = value
            phase += step
            if phase > 2 * Float.pi { phase -= 2 * Float.pi }
        }
        return out
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
