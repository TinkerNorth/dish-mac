// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import Foundation

/// The handlers for everything the satellite sends back to a pad: the two
/// feedback paths, the two version-2 paths, and the three audio messages.
/// Kept on the connection, not the client, so a reconnect's fresh client is
/// wired the same way without the router noticing.
struct ReturnPathHandlers {
    var rumble: ((RumbleCommand) -> Void)?
    var lightbar: ((LightbarCommand) -> Void)?
    var triggerEffects: ((TriggerEffectsCommand) -> Void)?
    var playerLeds: ((PlayerLedsCommand) -> Void)?
    var speakerAudio: ((AudioFrame) -> Void)?
    var hapticAudio: ((AudioFrame) -> Void)?
    var micLed: ((MicLedCommand) -> Void)?

    func install(on client: SatelliteClient) {
        client.onRumble = rumble
        client.onLightbar = lightbar
        client.onTriggerEffects = triggerEffects
        client.onPlayerLeds = playerLeds
        client.onSpeakerAudio = speakerAudio
        client.onHapticAudio = hapticAudio
        client.onMicLed = micLed
    }
}

extension WifiConnection {

    // MARK: - Return paths

    func setRumbleHandler(_ handler: @escaping (RumbleCommand) -> Void) {
        returnPaths.rumble = handler
        client?.onRumble = handler
    }

    func setLightbarHandler(_ handler: @escaping (LightbarCommand) -> Void) {
        returnPaths.lightbar = handler
        client?.onLightbar = handler
    }

    func setTriggerEffectsHandler(_ handler: @escaping (TriggerEffectsCommand) -> Void) {
        returnPaths.triggerEffects = handler
        client?.onTriggerEffects = handler
    }

    func setPlayerLedsHandler(_ handler: @escaping (PlayerLedsCommand) -> Void) {
        returnPaths.playerLeds = handler
        client?.onPlayerLeds = handler
    }

    func setSpeakerAudioHandler(_ handler: @escaping (AudioFrame) -> Void) {
        returnPaths.speakerAudio = handler
        client?.onSpeakerAudio = handler
    }

    func setHapticAudioHandler(_ handler: @escaping (AudioFrame) -> Void) {
        returnPaths.hapticAudio = handler
        client?.onHapticAudio = handler
    }

    func setMicLedHandler(_ handler: @escaping (MicLedCommand) -> Void) {
        returnPaths.micLed = handler
        client?.onMicLed = handler
    }

    var hasRumbleHandler: Bool {
        returnPaths.rumble != nil
    }

    var hasLightbarHandler: Bool {
        returnPaths.lightbar != nil
    }

    var hasTriggerEffectsHandler: Bool {
        returnPaths.triggerEffects != nil
    }

    var hasPlayerLedsHandler: Bool {
        returnPaths.playerLeds != nil
    }
}
