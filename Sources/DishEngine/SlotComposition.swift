// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// The pure folds the composition root runs on every emission: the switches
// in force per connection, the hot path's routing table, and the slot list
// the UI binds, with each binding's facts attached.

import DishCore
import Foundation

/// The switches in force per satellite: the global ones folded with the
/// bound controller's own, or the global ones alone while nothing is bound.
func connectionFlags(
    bindings: [String: String],
    connectionIds: some Collection<String>,
    global: ForwardingFlags,
    preferences: [String: SlotPreferences]
) -> [String: ForwardingFlags] {
    Dictionary(uniqueKeysWithValues: connectionIds.map { id in
        let slotId = bindings.first { $0.value == id }?.key
        let slot = slotId.flatMap { preferences[$0] } ?? SlotPreferences()
        return (id, effectiveFlags(global: global, slot: slot))
    })
}

/// The hot path's table, both views at once: slot → live sink and its
/// switches, satellite → bound slot and the same switches. A slot bound to
/// a Moonlight host routes to its pad on that host's link, under the
/// switches folded for the slot itself: the host carries up to four pads,
/// so the switches are the slot's, never the connection's.
func routeSnapshot(
    bindings: [String: String],
    pool: [String: WifiConnection],
    flags: [String: ForwardingFlags],
    global: ForwardingFlags,
    moonlight: [String: MoonlightConnection] = [:],
    preferences: [String: SlotPreferences] = [:]
) -> RoutingSnapshot {
    var snapshot = RoutingSnapshot()
    for (slotId, connectionId) in bindings {
        if let conn = pool[connectionId] {
            let inForce = flags[connectionId] ?? global
            snapshot.bySlot[slotId] = Route(sink: conn, flags: inForce)
            snapshot.byConnection[connectionId] = BoundSlotRoute(slotId: slotId, flags: inForce)
        } else if let host = moonlight[connectionId] {
            let inForce = effectiveFlags(global: global, slot: preferences[slotId] ?? SlotPreferences())
            snapshot.bySlot[slotId] = Route(sink: MoonlightPadSink(link: host.link, slotId: slotId), flags: inForce)
        }
    }
    return snapshot
}

/// What the slot list reads beside the bindings: the catalogs and probes
/// per satellite, the Emulate picks and the motion words per binding.
struct SlotFactsSnapshot {
    var catalogs: [String: CatalogDTO] = [:]
    var probes: [String: ServerCapabilitiesDTO] = [:]
    var overrides: [SlotKey: Int] = [:]
    var motion: [SlotKey: MotionBackendStatus] = [:]
    var preferences: [String: SlotPreferences] = [:]
    var routes: [String: PadAudioRoute] = [:]
    var audio: [String: ControllerAudioState] = [:]
    var mutes: Set<String> = []
    /// Each remembered Moonlight host's own emulated-type pick, a stored value.
    var moonlightHostTypes: [String: Int] = [:]
}

/// The UI's slot list: every connected controller, with its binding's
/// connection summary and the binding's facts attached.
func composeSlots(
    gcSlots: [GameControllerInput.Slot],
    connections: [ConnectionSummary],
    bindings: [String: String],
    facts: SlotFactsSnapshot = SlotFactsSnapshot()
) -> [ControllerSlot] {
    gcSlots.map { gc in
        let route = facts.routes[gc.id]
        var slot = ControllerSlot(id: gc.id, name: gc.name, capabilities: gc.capabilities.withAudio(route?.function), battery: gc.battery)
        slot.preferences = facts.preferences[gc.id] ?? SlotPreferences()
        slot.audioRoute = route?.verdict
        slot.micMuted = facts.mutes.contains(gc.id)
        slot.family = gc.family
        guard let connectionId = bindings[gc.id] else { return slot }
        slot.boundConnectionId = connectionId
        slot.boundStatus = connections.first { $0.id == connectionId }
        slot.audio = facts.audio[gc.id]
        attachBindingFacts(to: &slot, gc: gc, connectionId: connectionId, facts: facts)
        return slot
    }
}

/// The emulated type and its facts, the host's facts and the motion word
/// for one binding. A Moonlight binding's type is the pad's pick over the
/// host's own, in the host protocol's numbering; its types are the app's to
/// offer and word, and it has no catalog or probe.
func attachBindingFacts(to slot: inout ControllerSlot, gc: GameControllerInput.Slot, connectionId: String, facts: SlotFactsSnapshot) {
    let key = SlotKey(connectionId: connectionId, slotId: gc.id)
    if let hostType = facts.moonlightHostTypes[connectionId] {
        let pick = facts.overrides[key]
        let stored = MoonlightPadRules.migrateStoredType(pick ?? hostType)
        slot.emulation = SlotEmulation(type: Int(stored), isOverride: pick != nil, offered: [])
        slot.typeFeatures = moonlightTypeFeatures(MoonlightPadRules.resolveType(picked: stored, sourceHasMotion: gc.capabilities.hasMotion))
        slot.hostProbe = moonlightHostFacts
        return
    }
    let catalog = facts.catalogs[connectionId]
    let override = facts.overrides[key]
    let type = emulatedControllerType(override: override, catalog: catalog, family: gc.family)
    slot.emulation = SlotEmulation(type: type, isOverride: override != nil, offered: offerableTypes(in: catalog))
    slot.typeFeatures = typeFeatureFacts(in: catalog, type: type)
    slot.hostProbe = hostProbeFacts(facts.probes[connectionId])
    slot.motionStatus = facts.motion[key]
}

/// What a Moonlight host builds a pad of each type with (Wolf's
/// create_new_joypad): every type carries rumble and the trigger motors;
/// only a PlayStation pad gets motion, a touchpad and a lamp. No type
/// carries the pad's audio or the adaptive-trigger shapes, and the player
/// LEDs are this Mac's own.
func moonlightTypeFeatures(_ type: UInt8) -> TypeFeatureFacts {
    let ceiling = MoonlightPadRules.typeCeiling(type)
    let touchpad = ceiling & MoonlightCapability.touchpad != 0
    return TypeFeatureFacts(
        motion: ceiling & MoonlightCapability.gyro != 0,
        touchpad: touchpad,
        rumble: true,
        lightbar: ceiling & MoonlightCapability.rgbLed != 0,
        triggerEffects: false,
        playerLeds: true,
        mic: false,
        speaker: false,
        touchpadModes: touchpad ? ["ds4"] : []
    )
}

/// A Moonlight host carries rumble and never the mouse or the pad's audio:
/// the control stream has no lane for either, whatever host answers.
let moonlightHostFacts = HostProbeFacts(mouseControl: false, rumble: true, mic: false, speaker: false)
