// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import Foundation

/// What the app asks of the model: the satellites and the slots. The
/// Moonlight intents live beside the Moonlight wiring.
package extension AppModel {
    func clearFailure() {
        lastFailure = nil
    }

    /// A satellite's session ends; a Moonlight host's stops while its pads
    /// stay claimed.
    func disconnect(_ id: String) {
        if ConnectionHub.isMoonlight(id) {
            moonlight.disconnect(hostId: id)
        } else {
            wifi.disconnect(id: id)
        }
    }

    func connect(_ server: DiscoveredServer) {
        wifi.connect(to: server)
    }

    /// False when `input` is not a usable IPv4 address.
    @discardableResult
    func connectManual(_ input: String) -> Bool {
        guard let server = DiscoveredServer.manual(from: input) else { return false }
        wifi.connect(to: server)
        return true
    }

    /// Every trace of a connection goes, its bindings first.
    func forget(_ id: String) {
        for (slotId, connectionId) in hub.bindings where connectionId == id {
            hub.unbind(slotId: slotId)
        }
        if ConnectionHub.isMoonlight(id) {
            moonlight.forget(hostId: id)
        } else {
            wifi.forget(id: id)
        }
    }

    /// Both browses at once: the satellites' beacon and mDNS, and the Moonlight
    /// hosts' mDNS. The user asked, so the prompt it raises needs no more explaining.
    func startScan() {
        markLocalNetworkPrimed()
        wifi.startDiscovery()
        moonlight.startDiscovery()
    }

    /// The bound pad's detected capabilities, with its audio route folded
    /// in, become the descriptor's claims, and its family picks the catalog
    /// type it is emulated as.
    func bind(slotId: String, connectionId: String) {
        let pad = input.slots.first { $0.id == slotId }
        let capabilities = (pad?.capabilities ?? .none).withAudio(audio.routes.state[slotId]?.function)
        hub.bind(slotId: slotId, connectionId: connectionId, capabilities: capabilities, family: pad?.family ?? .other)
    }

    func unbind(slotId: String) {
        hub.unbind(slotId: slotId)
    }

    /// Flip one of a controller's own switches; the global one in Settings
    /// still outranks it.
    func setSlotSwitch(_ feature: SlotSwitch, on: Bool, slotId: String) {
        switch feature {
        case .motion: slotPreferences.setMotion(on, for: slotId)
        case .rumble: slotPreferences.setRumble(on, for: slotId)
        case .touchpad: slotPreferences.setTouchpad(on, for: slotId)
        case .mic:
            slotPreferences.setMic(on, for: slotId)
            if on { audio.requestMicrophoneLeave() }
        case .speaker: slotPreferences.setSpeaker(on, for: slotId)
        }
    }

    /// The touchpad's pick: the pad render, the host's mouse, or off. A
    /// pick that changes the session's desire re-PUTs the session.
    func setTouchpadPick(_ pick: TouchpadPick, slotId: String) {
        slotPreferences.setTouchpadPick(pick, for: slotId)
    }

    /// Mute or unmute one controller's microphone; muted sends nothing.
    func setMicMuted(_ muted: Bool, slotId: String) {
        audio.mutes.setMuted(muted, for: slotId)
    }

    /// The header chip's click: every live microphone mutes together, every
    /// muted one comes back together.
    func toggleAllMics() {
        audio.toggleAllMics()
    }

    /// Emulate the bound pad as `type`, or as its own family again for nil.
    func setEmulatedType(slotId: String, type: Int?) {
        let pad = input.slots.first { $0.id == slotId }
        hub.setEmulatedType(slotId: slotId, type: type, family: pad?.family ?? .other)
    }
}
