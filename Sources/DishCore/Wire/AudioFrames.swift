// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// Controller audio on the wire (contract §Controller audio, §Controller
// haptics): the emulated pad's OWN audio endpoints, never the host's game
// audio. MIC_AUDIO 0x0012 goes up, SPEAKER_AUDIO 0x0013 and HAPTIC_AUDIO
// 0x0015 come down, each `ctrlIdx(1) + seq(u16 BE) + one Opus packet`, and
// MIC_LED 0x0014 reports the lamp state the game asked for. The format is
// fixed, never negotiated.

import Foundation

public enum AudioWire {
    public static let sampleRate = 48000
    public static let frameMs = 20
    /// 20 ms at 48 kHz, per channel.
    public static let samplesPerChannel = 960
    public static let micChannels = 1
    public static let speakerChannels = 2
    public static let hapticChannels = 2
    /// ~32 kbps VBR, Opus VOIP, in-band FEC, DTX on.
    public static let micBitrate = 32000
    /// ~96 kbps VBR, Opus AUDIO, in-band FEC, for both down lanes.
    public static let speakerBitrate = 96000
    /// The server drops MIC_AUDIO beyond this per controller; nominal is 50.
    public static let micMaxPacketsPerSecond = 75
    /// The receiver's reorder window, in frames (40 ms).
    public static let reorderWindowFrames = 2
    /// ctrlIdx(1) + seq(2); the Opus packet is at least one byte.
    public static let headerBytes = 3
}

/// One audio message either way: which controller, the wrapping sequence
/// number, and exactly one self-delimiting Opus packet.
public struct AudioFrame: Equatable, Sendable {
    public var controllerIndex: UInt8
    public var seq: UInt16
    public var opus: Data

    public init(controllerIndex: UInt8, seq: UInt16, opus: Data) {
        self.controllerIndex = controllerIndex
        self.seq = seq
        self.opus = opus
    }

    /// Parse `ctrlIdx(1) + seq(u16 BE) + opus(>= 1)`; nil when the header is
    /// short or no Opus byte follows it (a silence frame is a one-byte DTX
    /// packet, never an empty one).
    public static func parse(_ payload: Data) -> AudioFrame? {
        let bytes = [UInt8](payload)
        guard bytes.count > AudioWire.headerBytes else { return nil }
        let seq = UInt16(bytes[1]) << 8 | UInt16(bytes[2])
        return AudioFrame(controllerIndex: bytes[0], seq: seq, opus: Data(bytes[AudioWire.headerBytes...]))
    }

    /// The payload behind the inner header.
    public var payload: Data {
        Data([controllerIndex, UInt8(seq >> 8), UInt8(seq & 0xFF)]) + opus
    }
}

/// The mic-mute lamp state the game asked for (MIC_LED 0x0014), advisory:
/// the client renders it, last writer wins against its own mute state.
public enum MicLedState: UInt8, Hashable, Sendable {
    case off = 0
    case on = 1
    case pulse = 2
}

public struct MicLedCommand: Equatable, Sendable {
    public var controllerIndex: UInt8
    public var state: MicLedState

    public init(controllerIndex: UInt8, state: MicLedState) {
        self.controllerIndex = controllerIndex
        self.state = state
    }

    /// Parse `ctrlIdx(1) + state(1)`; nil on truncation or a state byte this
    /// client does not know, which a newer server may send.
    public static func parse(_ payload: Data) -> MicLedCommand? {
        let bytes = [UInt8](payload)
        guard bytes.count >= ProtocolConstants.micLedPayloadBytes, let state = MicLedState(rawValue: bytes[1]) else { return nil }
        return MicLedCommand(controllerIndex: bytes[0], state: state)
    }
}

/// The DualSense mic-mute button is the one free XINPUT bit of the report's
/// button word. Mute is the client's to enforce: muted means zero MIC_AUDIO
/// packets on the wire, and the bit set so host software can see the state.
public enum MicMute {
    public static let buttonBit: UInt16 = 0x0800

    public static func buttons(_ buttons: UInt16, muted: Bool) -> UInt16 {
        muted ? buttons | buttonBit : buttons & ~buttonBit
    }

    /// A muted client delivers no capture at all, silent frames included.
    public static func mayStream(muted: Bool, capAdvertised: Bool) -> Bool {
        !muted && capAdvertised
    }
}
