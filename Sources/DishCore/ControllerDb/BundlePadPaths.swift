// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// Every controller path, input and output, for the diagnostics bundle: what
// went in and what came out of each pad as counts and the last value, never
// a stream. A field the path cannot know is null, not invented.

import Foundation

public struct BundlePadInput: Equatable, Sendable {
    public let frames: UInt64
    /// Nil while no rate was measured.
    public let rateHz: Int?
    /// The last report published, after the dead zones; nil before the first.
    public let last: GamepadReport?

    public init(frames: UInt64, rateHz: Int?, last: GamepadReport?) {
        self.frames = frames
        self.rateHz = rateHz
        self.last = last
    }
}

/// Where a pad's rumble goes on this Mac.
public enum BundleOutputTarget: String, Equatable, Sendable {
    /// Dish writes the pad's own report.
    case directUsb
    /// GameController drives the motors.
    case framework
    /// Nothing carries it.
    case none
}

public struct RumbleFacts: Equatable, Sendable {
    public let strong: UInt16
    public let weak: UInt16
    public let durationMs: UInt16
    public let atMs: Int64

    public init(strong: UInt16, weak: UInt16, durationMs: UInt16, atMs: Int64) {
        self.strong = strong
        self.weak = weak
        self.durationMs = durationMs
        self.atMs = atMs
    }
}

public struct LightbarFacts: Equatable, Sendable {
    public let r: UInt8
    public let g: UInt8
    public let b: UInt8
    public let atMs: Int64

    public init(r: UInt8, g: UInt8, b: UInt8, atMs: Int64) {
        self.r = r
        self.g = g
        self.b = b
        self.atMs = atMs
    }
}

/// Every feedback command that reached the pad, whichever host sent it or
/// the inspector's own tests, counted where the pad's feedback lands.
public struct PadOutputCounts: Equatable, Sendable {
    public let rumble: Int
    public let lastRumble: RumbleFacts?
    public let lightbar: Int
    public let lastLightbar: LightbarFacts?
    public let playerLeds: Int
    public let lastPlayer: Int?
    public let triggerEffects: Int

    public init(
        rumble: Int = 0,
        lastRumble: RumbleFacts? = nil,
        lightbar: Int = 0,
        lastLightbar: LightbarFacts? = nil,
        playerLeds: Int = 0,
        lastPlayer: Int? = nil,
        triggerEffects: Int = 0
    ) {
        self.rumble = rumble
        self.lastRumble = lastRumble
        self.lightbar = lightbar
        self.lastLightbar = lastLightbar
        self.playerLeds = playerLeds
        self.lastPlayer = lastPlayer
        self.triggerEffects = triggerEffects
    }
}

public enum BundleVoiceState: String, Equatable, Sendable {
    case open
    case closed
    case refused
}

/// One of the pad's audio voices as the audio plan has it.
public struct BundleVoice: Equatable, Sendable {
    public let voice: BundleVoiceState
    /// `pad` when the pad's own endpoint is routed; nil when none is.
    public let device: String?
    public let frames: Int

    public init(voice: BundleVoiceState, device: String?, frames: Int) {
        self.voice = voice
        self.device = device
        self.frames = frames
    }
}

/// A refusal outranks the plan: the system would not open the endpoint.
public func bundleVoice(open: Bool, refused: Bool, routed: Bool, frames: Int) -> BundleVoice {
    let state: BundleVoiceState = if refused { .refused } else if open { .open } else { .closed }
    return BundleVoice(voice: state, device: routed ? "pad" : nil, frames: frames)
}

public struct BundlePadOutput: Equatable, Sendable {
    public let counts: PadOutputCounts
    public let rumbleTarget: BundleOutputTarget
    public let lastWrite: DirectWriteVerdict?
    /// The mic lamp the game asked for, `off`, `on` or `pulse`; nil when
    /// none has been asked.
    public let micLed: String?
    /// Nil while the audio catalog has not been read.
    public let speaker: BundleVoice?
    public let haptics: BundleVoice?

    public init(
        counts: PadOutputCounts,
        rumbleTarget: BundleOutputTarget,
        lastWrite: DirectWriteVerdict?,
        micLed: String?,
        speaker: BundleVoice?,
        haptics: BundleVoice?
    ) {
        self.counts = counts
        self.rumbleTarget = rumbleTarget
        self.lastWrite = lastWrite
        self.micLed = micLed
        self.speaker = speaker
        self.haptics = haptics
    }
}

/// The radio link a Bluetooth pad's HID runs over, in the contract's words.
public enum BluetoothTransportLayer: String, Equatable, Sendable {
    /// HID over L2CAP, the HID profile (service 0x1124).
    case classic
    /// HID over GATT (service 0x1812).
    case le
}

/// What the Mac knows of a Bluetooth pad's link: macOS reads every one
/// through its HID stack, and IOKit's transport word names the layer.
public struct BundleBluetooth: Equatable, Sendable {
    public let profile: String
    public let transportLayer: String?

    public init(profile: String, transportLayer: String?) {
        self.profile = profile
        self.transportLayer = transportLayer
    }
}

/// Nil for a pad that is not on Bluetooth, or whose transport is unknown.
public func bundleBluetooth(_ transport: ControllerTransport?, layer: BluetoothTransportLayer?) -> BundleBluetooth? {
    guard transport == .bluetooth else { return nil }
    return BundleBluetooth(profile: "hid", transportLayer: layer?.rawValue)
}

// MARK: - The encoded shape

enum BundlePadPathsFile {
    struct Input: Encodable {
        let frames: UInt64
        let rateHz: Int?
        let last: Report?

        private enum CodingKeys: String, CodingKey { case frames, rateHz, last }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(frames, forKey: .frames)
            try container.encode(rateHz, forKey: .rateHz)
            try container.encode(last, forKey: .last)
        }
    }

    struct Report: Encodable {
        let buttons: String
        let lx: Int16
        let ly: Int16
        let rx: Int16
        let ry: Int16
        let lt: UInt8
        let rt: UInt8
        let ext: String
    }

    struct RumbleLast: Encodable {
        let strong: UInt16
        let weak: UInt16
        let durationMs: UInt16
        let atMs: Int64
    }

    struct LightbarLast: Encodable {
        let r: UInt8
        let g: UInt8
        let b: UInt8
        let atMs: Int64
    }

    struct PlayerLast: Encodable {
        let player: Int
    }

    struct MicLedLast: Encodable {
        let state: String
    }

    /// One lane: its count (null where this Mac cannot count it), and
    /// whatever else the lane knows.
    struct Lane<Last: Encodable>: Encodable {
        let count: Int?
        let last: Last?
        var target: String?
        var lastWrite: BundleFile.Write?

        private enum CodingKeys: String, CodingKey { case count, last, target, lastWrite }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(count, forKey: .count)
            try container.encodeIfPresent(last, forKey: .last)
            try container.encodeIfPresent(target, forKey: .target)
            try container.encodeIfPresent(lastWrite, forKey: .lastWrite)
        }
    }

    struct Voice: Encodable {
        let voice: String
        let device: String?
        let frames: Int

        private enum CodingKeys: String, CodingKey { case voice, device, frames }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(voice, forKey: .voice)
            try container.encode(device, forKey: .device)
            try container.encode(frames, forKey: .frames)
        }
    }

    struct Nothing: Encodable {}

    struct Output: Encodable {
        let rumble: Lane<RumbleLast>
        let triggerRumble: Lane<Nothing>
        let lightbar: Lane<LightbarLast>
        let playerLeds: Lane<PlayerLast>
        let triggerEffects: Lane<Nothing>
        let micLed: Lane<MicLedLast>
        let speaker: Voice?
        let haptics: Voice?

        private enum CodingKeys: String, CodingKey {
            case rumble, triggerRumble, lightbar, playerLeds, triggerEffects, micLed, speaker, haptics
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(rumble, forKey: .rumble)
            try container.encode(triggerRumble, forKey: .triggerRumble)
            try container.encode(lightbar, forKey: .lightbar)
            try container.encode(playerLeds, forKey: .playerLeds)
            try container.encode(triggerEffects, forKey: .triggerEffects)
            try container.encode(micLed, forKey: .micLed)
            try container.encode(speaker, forKey: .speaker)
            try container.encode(haptics, forKey: .haptics)
        }
    }

    struct Bluetooth: Encodable {
        let profile: String
        let transportLayer: String?

        private enum CodingKeys: String, CodingKey { case profile, transportLayer }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(profile, forKey: .profile)
            try container.encode(transportLayer, forKey: .transportLayer)
        }
    }
}

func bundleInput(_ input: BundlePadInput) -> BundlePadPathsFile.Input {
    BundlePadPathsFile.Input(frames: input.frames, rateHz: input.rateHz, last: input.last.map(bundleReport))
}

private func bundleReport(_ report: GamepadReport) -> BundlePadPathsFile.Report {
    BundlePadPathsFile.Report(
        buttons: String(format: "%04x", UInt32(report.buttons)),
        lx: report.lx,
        ly: report.ly,
        rx: report.rx,
        ry: report.ry,
        lt: report.lt,
        rt: report.rt,
        ext: String(format: "%08x", report.extButtons)
    )
}

/// The Mac folds a host's trigger rumble into the motors before the pad's
/// feedback counts it, so that lane's count is not known apart.
func bundleOutput(_ output: BundlePadOutput, write: BundleFile.Write?) -> BundlePadPathsFile.Output {
    let counts = output.counts
    let rumbleLast = counts.lastRumble.map {
        BundlePadPathsFile.RumbleLast(strong: $0.strong, weak: $0.weak, durationMs: $0.durationMs, atMs: $0.atMs)
    }
    let lightbarLast = counts.lastLightbar.map { BundlePadPathsFile.LightbarLast(r: $0.r, g: $0.g, b: $0.b, atMs: $0.atMs) }
    return BundlePadPathsFile.Output(
        rumble: BundlePadPathsFile.Lane(count: counts.rumble, last: rumbleLast, target: output.rumbleTarget.rawValue, lastWrite: write),
        triggerRumble: BundlePadPathsFile.Lane<BundlePadPathsFile.Nothing>(count: nil, last: nil),
        lightbar: BundlePadPathsFile.Lane(count: counts.lightbar, last: lightbarLast),
        playerLeds: BundlePadPathsFile.Lane(count: counts.playerLeds, last: counts.lastPlayer.map(BundlePadPathsFile.PlayerLast.init)),
        triggerEffects: BundlePadPathsFile.Lane<BundlePadPathsFile.Nothing>(count: counts.triggerEffects, last: nil),
        micLed: BundlePadPathsFile.Lane(count: nil, last: output.micLed.map(BundlePadPathsFile.MicLedLast.init)),
        speaker: output.speaker.map(bundleVoiceFile),
        haptics: output.haptics.map(bundleVoiceFile)
    )
}

private func bundleVoiceFile(_ voice: BundleVoice) -> BundlePadPathsFile.Voice {
    BundlePadPathsFile.Voice(voice: voice.voice.rawValue, device: voice.device, frames: voice.frames)
}

func bundleBluetoothFile(_ bluetooth: BundleBluetooth) -> BundlePadPathsFile.Bluetooth {
    BundlePadPathsFile.Bluetooth(profile: bluetooth.profile, transportLayer: bluetooth.transportLayer)
}
