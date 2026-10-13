// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import XCTest
@testable import DishCore

/// The audio messages' fixed shape, the mic lamp, and the mute invariant.
final class AudioFramesTests: XCTestCase {

    func testAFrameRoundTripsWithABigEndianSequence() {
        let frame = AudioFrame(controllerIndex: 2, seq: 0x1234, opus: Data([0xFC, 0x01, 0x02]))
        XCTAssertEqual([UInt8](frame.payload), [2, 0x12, 0x34, 0xFC, 0x01, 0x02])
        XCTAssertEqual(AudioFrame.parse(frame.payload), frame)
    }

    func testASilenceFrameIsOneDtxByteNeverEmpty() {
        XCTAssertNotNil(AudioFrame.parse(Data([0, 0, 1, 0xF8])), "a one-byte DTX packet is a frame")
        XCTAssertNil(AudioFrame.parse(Data([0, 0, 1])), "a header with no Opus byte is malformed")
        XCTAssertNil(AudioFrame.parse(Data([0, 0])))
        XCTAssertNil(AudioFrame.parse(Data()))
    }

    func testTheWireIsFixed() {
        XCTAssertEqual(AudioWire.sampleRate, 48000)
        XCTAssertEqual(AudioWire.samplesPerChannel, 960)
        XCTAssertEqual(AudioWire.frameMs, 20)
        XCTAssertEqual(AudioWire.micChannels, 1)
        XCTAssertEqual(AudioWire.speakerChannels, 2)
        XCTAssertEqual(AudioWire.hapticChannels, 2)
        XCTAssertEqual(AudioWire.reorderWindowFrames, 2)
        XCTAssertEqual(AudioWire.micMaxPacketsPerSecond, 75)
    }

    func testTheMicLampHasThreeStatesAndIgnoresAFourth() {
        XCTAssertEqual(MicLedCommand.parse(Data([1, 0])), MicLedCommand(controllerIndex: 1, state: .off))
        XCTAssertEqual(MicLedCommand.parse(Data([1, 1])), MicLedCommand(controllerIndex: 1, state: .on))
        XCTAssertEqual(MicLedCommand.parse(Data([1, 2])), MicLedCommand(controllerIndex: 1, state: .pulse))
        XCTAssertNil(MicLedCommand.parse(Data([1, 3])), "a state a newer server invented is not rendered as a guess")
        XCTAssertNil(MicLedCommand.parse(Data([1])))
    }

    func testMuteSetsTheOneFreeButtonBitAndStopsTheStream() {
        XCTAssertEqual(MicMute.buttonBit, 0x0800)
        XCTAssertEqual(MicMute.buttons(0x0001, muted: true), 0x0801)
        XCTAssertEqual(MicMute.buttons(0x0801, muted: false), 0x0001)
        XCTAssertTrue(MicMute.mayStream(muted: false, capAdvertised: true))
        XCTAssertFalse(MicMute.mayStream(muted: true, capAdvertised: true), "muted means zero packets, not silent ones")
        XCTAssertFalse(MicMute.mayStream(muted: false, capAdvertised: false), "no cap, no stream")
    }
}
