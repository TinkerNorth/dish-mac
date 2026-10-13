// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Foundation

extension L10n {

    // MARK: - The controller's own audio

    var mic: String {
        catalog.text("Mic")
    }

    var micLive: String {
        catalog.text("Mic live")
    }

    var micMuted: String {
        catalog.text("Mic muted")
    }

    var muteMic: String {
        catalog.text("Mute mic")
    }

    var unmuteMic: String {
        catalog.text("Unmute mic")
    }

    var micLiveClickToMute: String {
        catalog.text("Microphone is live. Click to mute it.")
    }

    var micMutedClickToUnmute: String {
        catalog.text("Microphone muted. Click to unmute it.")
    }

    var micPermissionOff: String {
        catalog.text("Microphone permission is off for Dish. Turn it on in system settings to use the controller microphone.")
    }

    var micCarriesYourVoice: String {
        catalog.text("The pad’s mic carries your voice to the host. Off sends nothing.")
    }

    var hostAudioPlaysOnThePad: String {
        catalog.text("Audio from the host plays on the pad’s speaker or headset.")
    }

    var micLamp: String {
        catalog.text("Mic lamp")
    }

    var on: String {
        catalog.text("On")
    }

    var pulse: String {
        catalog.text("Pulse")
    }

    // MARK: - Why this Mac routes none of the pad's audio

    var padAudioNeedsUsb: String {
        catalog.text("The pad’s audio needs USB; over Bluetooth it has no channel.")
    }

    var padNameSharedReason: String {
        catalog.text("Two controllers share one name, so neither gets its audio.")
    }

    var endpointNameSharedReason: String {
        catalog.text("macOS lists more than one audio device under this pad’s name, so its audio is not routed.")
    }

    // MARK: - The Diagnostics lines

    var controllerAudio: String {
        catalog.text("Controller audio")
    }

    var noUsbAudioFunction: String {
        catalog.text("no USB audio function on this controller")
    }

    var twoControllersShareOneName: String {
        catalog.text("two controllers share one name, so neither is routed")
    }

    var moreThanOneAudioDevice: String {
        catalog.text("macOS lists more than one audio device under its name, so it is not routed")
    }

    var armedMuted: String {
        catalog.text("armed, muted")
    }

    var capturing: String {
        catalog.text("capturing")
    }

    var playing: String {
        catalog.text("playing")
    }

    var idle: String {
        catalog.text("idle")
    }

    var haptics: String {
        catalog.text("Haptics")
    }

    func framesSent(_ count: Int) -> String {
        catalog.format("%lld sent", count)
    }

    func playedAndConcealed(_ played: Int, _ concealed: Int) -> String {
        catalog.format("%lld played · %lld concealed", played, concealed)
    }
}
