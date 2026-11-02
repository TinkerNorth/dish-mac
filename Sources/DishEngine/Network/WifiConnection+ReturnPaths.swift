// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import Foundation

/// The handlers for everything the satellite sends back to a pad: the two
/// feedback paths, the two version-2 paths, and the three audio messages.
/// Kept on the connection, not the client, so a reconnect's fresh client is
/// wired the same way without the router noticing. The audio messages go
/// through the connection's table, to the pad that holds the frame's index.
struct ReturnPathHandlers {
    var rumble: ((RumbleCommand) -> Void)?
    var lightbar: ((LightbarCommand) -> Void)?
    var triggerEffects: ((TriggerEffectsCommand) -> Void)?
    var playerLeds: ((PlayerLedsCommand) -> Void)?
    var speakerAudio: ((AudioFrame) -> Void)?
    var hapticAudio: ((AudioFrame) -> Void)?
    var micLed: ((MicLedCommand) -> Void)?

    init(audio: PadAudioTable) {
        speakerAudio = audio.speaker
        hapticAudio = audio.haptic
        micLed = audio.micLed
    }

    /// One post of the whole set to the client's receive loop.
    func install(on client: SatelliteClient) {
        client.updateHandlers { handlers in
            handlers.rumble = rumble
            handlers.lightbar = lightbar
            handlers.triggerEffects = triggerEffects
            handlers.playerLeds = playerLeds
            handlers.speakerAudio = speakerAudio
            handlers.hapticAudio = hapticAudio
            handlers.micLed = micLed
        }
    }
}

/// One pad's audio handlers on a satellite: its two lanes and its lamp.
struct PadAudioHandlers {
    let speaker: (AudioFrame) -> Void
    let haptic: (AudioFrame) -> Void
    let micLed: (MicLedCommand) -> Void
}

/// Each pad's audio handlers by controller index: written on the main actor
/// as a pad's audio binds and lets go, read on the receive queue once per
/// frame, so the speaker of the pad on index 1 never plays index 0's lane.
final class PadAudioTable: @unchecked Sendable {
    private var handlers: [Int: PadAudioHandlers] = [:]
    private var lock = TrackedLock(os_unfair_lock_s(), "connection.padAudio")

    func set(_ pad: PadAudioHandlers?, for controllerIndex: Int) {
        lock.lock()
        defer { lock.unlock() }
        handlers[controllerIndex] = pad
    }

    func handlers(for controllerIndex: UInt8) -> PadAudioHandlers? {
        lock.lock()
        defer { lock.unlock() }
        return handlers[Int(controllerIndex)]
    }

    func speaker(_ frame: AudioFrame) {
        handlers(for: frame.controllerIndex)?.speaker(frame)
    }

    func haptic(_ frame: AudioFrame) {
        handlers(for: frame.controllerIndex)?.haptic(frame)
    }

    func micLed(_ command: MicLedCommand) {
        handlers(for: command.controllerIndex)?.micLed(command)
    }
}

extension WifiConnection {

    // MARK: - Return paths

    /// The router's routes for this connection's indices, captured by the
    /// four feedback handlers and kept for a reconnect's fresh client.
    func setFeedbackRoutes(_ routes: FeedbackRoutes) {
        returnPaths.rumble = routes.rumble
        returnPaths.lightbar = routes.lightbar
        returnPaths.triggerEffects = routes.triggerEffects
        returnPaths.playerLeds = routes.playerLeds
        if let client { returnPaths.install(on: client) }
    }

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

    /// One pad's audio handlers on its index, or none once it lets go.
    func setPadAudio(_ pad: PadAudioHandlers?, controllerIndex: Int) {
        padAudio.set(pad, for: controllerIndex)
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
