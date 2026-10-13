// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import XCTest
@testable import DishEngine

/// The system's Opus codec in the wire's shape: a frame in, a packet out,
/// the packet back to a window; a concealed window is silence.
final class OpusCodecTests: XCTestCase {

    private func tone(channels: Int, hz: Float = 440, amplitude: Float = 0.3) -> [Float] {
        (0 ..< AudioWire.samplesPerChannel * channels).map { index in
            let sample = index / channels
            return amplitude * sinf(2 * .pi * hz * Float(sample) / Float(AudioWire.sampleRate))
        }
    }

    private func rms(_ samples: [Float]) -> Float {
        sqrtf(samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count))
    }

    func testAMonoFrameBecomesOneSmallPacketAndComesBackAsSound() throws {
        let encoder = try XCTUnwrap(OpusEncoder(channels: AudioWire.micChannels, bitrate: AudioWire.micBitrate))
        let decoder = try XCTUnwrap(OpusDecoder(channels: AudioWire.micChannels))
        var loudest: Float = 0
        for _ in 0 ..< 10 {
            let packet = try XCTUnwrap(encoder.encode(tone(channels: 1)))
            XCTAssertGreaterThan(packet.count, 0)
            XCTAssertLessThan(packet.count, 400, "about 32 kbps is at most 80 bytes a frame; the first frames may be larger")
            let window = decoder.decode(packet)
            XCTAssertEqual(window.count, AudioWire.samplesPerChannel)
            loudest = max(loudest, rms(window))
        }
        XCTAssertGreaterThan(loudest, 0.1, "the tone survives the round trip")
    }

    func testAStereoFrameRoundTripsForTheDownLanes() throws {
        let encoder = try XCTUnwrap(OpusEncoder(channels: AudioWire.speakerChannels, bitrate: AudioWire.speakerBitrate))
        let decoder = try XCTUnwrap(OpusDecoder(channels: AudioWire.speakerChannels))
        var loudest: Float = 0
        for _ in 0 ..< 10 {
            let packet = try XCTUnwrap(encoder.encode(tone(channels: 2)))
            let window = decoder.decode(packet)
            XCTAssertEqual(window.count, AudioWire.samplesPerChannel * 2)
            loudest = max(loudest, rms(window))
        }
        XCTAssertGreaterThan(loudest, 0.1)
    }

    func testTheWrongFrameLengthIsRefused() throws {
        let encoder = try XCTUnwrap(OpusEncoder(channels: 1, bitrate: AudioWire.micBitrate))
        XCTAssertNil(encoder.encode([Float](repeating: 0, count: 480)), "10 ms is not the wire's frame")
        XCTAssertNil(encoder.encode([]))
    }

    func testAConcealedOrRejectedWindowIsSilenceOfTheRightLength() throws {
        let decoder = try XCTUnwrap(OpusDecoder(channels: 2))
        XCTAssertEqual(decoder.decode(nil), [Float](repeating: 0, count: AudioWire.samplesPerChannel * 2))
        XCTAssertEqual(decoder.decode(Data()).count, AudioWire.samplesPerChannel * 2)
        XCTAssertEqual(
            decoder.decode(Data([0xFF, 0xFF, 0xFF, 0xFF])).count,
            AudioWire.samplesPerChannel * 2,
            "garbage never shortens the window"
        )
    }
}
