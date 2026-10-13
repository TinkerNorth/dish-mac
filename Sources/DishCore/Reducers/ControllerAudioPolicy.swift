// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// The decisions behind controller audio, as the fleet makes them: what the
// host will carry right now (its probe folded the way dish-android folds
// it), which voices open and whether the microphone captures (the desktop
// clients' eligibility), which caps the descriptor advertises, and the one
// app-wide microphone chip with its mute-all.

import Foundation

/// What the satellite will actually carry, per direction, from its
/// capabilities probe. A probe that never landed carries nothing: audio is
/// opt-in by design, so the honest answer before a probe is "not carried".
public struct HostAudioVerdict: Equatable, Sendable {
    public var mic: Bool
    public var speaker: Bool
    public var hapticAudio: Bool

    public init(mic: Bool, speaker: Bool, hapticAudio: Bool) {
        self.mic = mic
        self.speaker = speaker
        self.hapticAudio = hapticAudio
    }

    public static let none = HostAudioVerdict(mic: false, speaker: false, hapticAudio: false)
}

/// The probe's `controllerAudio` block, already ANDed with `enabled` by the
/// host, is the verdict; an older satellite without the block carries audio
/// wherever a backend that can build an audio persona is available, and
/// never the haptics lanes.
public func hostAudioVerdict(
    blockPresent: Bool,
    enabled: Bool,
    mic: Bool,
    speaker: Bool,
    hapticAudio: Bool,
    anyBackendAudio: Bool
) -> HostAudioVerdict {
    guard blockPresent else { return HostAudioVerdict(mic: anyBackendAudio, speaker: anyBackendAudio, hapticAudio: false) }
    return HostAudioVerdict(mic: enabled && mic, speaker: enabled && speaker, hapticAudio: enabled && hapticAudio)
}

/// The facts one binding's audio is decided from.
public struct AudioFacts: Equatable, Sendable {
    /// The pad's own audio function on this Mac.
    public var routeMic: Bool
    public var routeSpeaker: Bool
    public var routeHapticLanes: Bool
    /// The controller's switches: the mic off until asked, the speaker on,
    /// and the speaker switch covering the haptics lanes too.
    public var micOn: Bool
    public var speakerOn: Bool
    public var host: HostAudioVerdict
    /// A live session carrying this slot.
    public var live: Bool
    /// The system granted this app the microphone.
    public var micPermitted: Bool
    public var muted: Bool

    public init(
        routeMic: Bool = false,
        routeSpeaker: Bool = false,
        routeHapticLanes: Bool = false,
        micOn: Bool = false,
        speakerOn: Bool = true,
        host: HostAudioVerdict = .none,
        live: Bool = false,
        micPermitted: Bool = false,
        muted: Bool = false
    ) {
        self.routeMic = routeMic
        self.routeSpeaker = routeSpeaker
        self.routeHapticLanes = routeHapticLanes
        self.micOn = micOn
        self.speakerOn = speakerOn
        self.host = host
        self.live = live
        self.micPermitted = micPermitted
        self.muted = muted
    }
}

/// What runs and what is advertised. A cap says what the CLIENT can do and
/// will do once asked: the route and the switch, like every other cap; the
/// host gates its own sends. A voice opens only when the host will feed it.
public struct AudioPlan: Hashable, Sendable {
    public var capture: Bool
    public var speakerVoice: Bool
    public var hapticVoice: Bool
    public var capMic: Bool
    public var capSpeaker: Bool
    public var capHapticAudio: Bool
    /// The mic is armed when everything but the mute allows capture: the
    /// chip shows an armed mic as live or muted.
    public var micArmed: Bool

    public init(
        capture: Bool, speakerVoice: Bool, hapticVoice: Bool, capMic: Bool, capSpeaker: Bool, capHapticAudio: Bool, micArmed: Bool
    ) {
        self.capture = capture
        self.speakerVoice = speakerVoice
        self.hapticVoice = hapticVoice
        self.capMic = capMic
        self.capSpeaker = capSpeaker
        self.capHapticAudio = capHapticAudio
        self.micArmed = micArmed
    }

    public static let silent = AudioPlan(
        capture: false, speakerVoice: false, hapticVoice: false, capMic: false, capSpeaker: false, capHapticAudio: false, micArmed: false
    )
}

public func audioPlan(_ facts: AudioFacts) -> AudioPlan {
    let capMic = facts.routeMic && facts.micOn
    let capSpeaker = facts.routeSpeaker && facts.speakerOn
    let capHaptic = facts.routeHapticLanes && facts.speakerOn
    let armed = facts.live && capMic && facts.host.mic && facts.micPermitted
    return AudioPlan(
        capture: armed && !facts.muted,
        speakerVoice: facts.live && capSpeaker && facts.host.speaker,
        hapticVoice: facts.live && capHaptic && facts.host.hapticAudio,
        capMic: capMic,
        capSpeaker: capSpeaker,
        capHapticAudio: capHaptic,
        micArmed: armed
    )
}

/// The app-wide microphone chip: hidden while nothing is armed, live while
/// anything delivers, muted while everything armed is muted.
public enum MicIndicatorState: Equatable, Sendable {
    case hidden
    case live
    case muted
}

public func micIndicator(armed: Int, delivering: Int) -> MicIndicatorState {
    if armed == 0 { return .hidden }
    return delivering > 0 ? .live : .muted
}

/// What one tap on the chip does to every armed microphone, all or nothing.
public enum MicToggleAll: Equatable, Sendable {
    case muteAll
    case unmuteAll
    case nothing
}

public func micToggleAll(_ state: MicIndicatorState) -> MicToggleAll {
    switch state {
    case .hidden: .nothing
    case .live: .muteAll
    case .muted: .unmuteAll
    }
}
