// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// What the bindings ask of every Moonlight host, and how a host reads as a
// row: pure, so both are pinned without a manager. The sibling of
// dish-android's MoonlightSessionController.desiredPads and MoonlightRows.

import DishCore
import Foundation

enum MoonlightDesire {
    /// The pad a bound slot asks its host for: the stored pick resolved
    /// against what the pad can feed. The motion switch and the touchpad pick
    /// fold in, because the host reads the motion bits at arrival and expects
    /// touches only on a pad announced with a touchpad; the rest are facts
    /// about the hardware, and the switches gate their delivery instead.
    static func request(
        slotId: String,
        capabilities: ControllerCapabilities,
        storedType: Int,
        flags: ForwardingFlags
    ) -> MoonlightPadRequest {
        let source = MoonlightSourceCapabilities(
            rumble: capabilities.hasRumble,
            triggerRumble: capabilities.hasTriggerEffects,
            motion: capabilities.hasMotion && flags.motion,
            touchpad: capabilities.hasTouchpad && flags.touchpad && flags.touchpadPick == .pad,
            battery: capabilities.hasBattery,
            lightbar: capabilities.hasLightbar
        )
        return MoonlightPadRequest(slotId: slotId, announced: MoonlightPadRules.arrival(storedType: storedType, source: source))
    }

    /// Every Moonlight host's pads from the bindings: a slot bound to a host
    /// the manager knows, whose pad is present. The pick per binding beats
    /// the host's own; the switches are the slot's under the global ones.
    static func desiredPads(
        bindings: [String: String],
        hostIds: Set<String>,
        slots: [GameControllerInput.Slot],
        overrides: [SlotKey: Int],
        hostTypes: (String) -> Int,
        preferences: [String: SlotPreferences],
        global: ForwardingFlags
    ) -> [String: [MoonlightPadRequest]] {
        var out: [String: [MoonlightPadRequest]] = [:]
        for (slotId, hostId) in bindings.sorted(by: { $0.key < $1.key }) where hostIds.contains(hostId) {
            guard let slot = slots.first(where: { $0.id == slotId }) else { continue }
            let flags = effectiveFlags(global: global, slot: preferences[slotId] ?? SlotPreferences())
            let type = overrides[SlotKey(connectionId: hostId, slotId: slotId)] ?? hostTypes(hostId)
            out[hostId, default: []].append(request(slotId: slotId, capabilities: slot.capabilities, storedType: type, flags: flags))
        }
        return out
    }

    /// The chip a host's row wears: the live phase first, then the trust the
    /// records hold. A host with no pairing reads Needs pairing; a paired one
    /// reads Ready when seen or proved this process, Offline otherwise; a
    /// drop reads Unsteady, as a satellite's faltering link does.
    static func linkState(phase: MoonlightSessionPhase, paired: Bool, verified: Bool, discovered: Bool) -> LinkState {
        switch phase {
        case .streaming: return .connected
        case .checkingInfo, .launching, .rtsp, .controlConnecting: return .connecting
        case .failed(.dropped): return .unstable
        case .failed(.trustLost), .failed(.hostReplaced), .failed(.notPaired): return .stale
        case .idle, .failed: break
        }
        guard paired else { return .stale }
        return discovered || verified ? .ready : .saved
    }

    /// A host's row: its name (its address when it has none), the address
    /// with the protocol's name, the chip, and every slot bound to it.
    static func summary(
        host: MoonlightHost,
        phase: MoonlightSessionPhase,
        roundTripMs: Int64?,
        paired: Bool,
        verified: Bool,
        discovered: Bool,
        boundSlotIds: [String]
    ) -> ConnectionSummary {
        ConnectionSummary(
            id: host.id,
            label: host.name.isEmpty ? host.address : host.name,
            detail: "\(host.address) • Moonlight",
            live: linkState(phase: phase, paired: paired, verified: verified, discovered: discovered),
            boundSlotId: boundSlotIds.first,
            latencyMs: roundTripMs.map { Double($0) / 2 },
            compat: .unknown,
            kind: .moonlight,
            boundSlotIds: boundSlotIds
        )
    }
}
