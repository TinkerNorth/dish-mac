// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import Foundation

/// The physical pad's family, decided once at attach from the framework's
/// product category. It picks the catalog type the pad is emulated as. The
/// framework names these three; everything else is a generic pad.
package enum PadFamily: Hashable {
    case dualSense
    case dualShock4
    case xbox
    case other
}

/// The caps word a descriptor advertises. A cap is a promise that the
/// matching stream or return path lands, so it needs both the hardware and
/// the user's switch: a feature turned off in Settings is not advertised.
/// Analog triggers ride every extended gamepad. The audio caps follow the
/// pad's audio function and the controller's own switches, the speaker
/// switch covering the haptics lanes, as on the other clients.
func descriptorCaps(_ capabilities: ControllerCapabilities, _ flags: ForwardingFlags) -> UInt16 {
    let claims: [(claimed: Bool, bit: UInt16)] = [
        (true, ProtocolConstants.capAnalogTriggers),
        (capabilities.hasRumble && flags.rumble, ProtocolConstants.capRumble),
        (capabilities.hasMotion && flags.motion, ProtocolConstants.capMotion),
        (capabilities.hasLightbar && flags.lightbar, ProtocolConstants.capLightbar),
        (capabilities.hasTriggerEffects, ProtocolConstants.capTriggerEffects),
        (capabilities.hasPlayerLeds, ProtocolConstants.capPlayerLeds),
        (capabilities.hasMic && flags.mic, ProtocolConstants.capMic),
        (capabilities.hasSpeaker && flags.speaker, ProtocolConstants.capSpeaker),
        (capabilities.hasHapticLanes && flags.speaker, ProtocolConstants.capHapticAudio)
    ]
    return claims.filter(\.claimed).reduce(UInt16(0)) { $0 | $1.bit }
}

/// What the descriptor's touchpad ladder reads beside the pick: the
/// catalog's word on whether the emulated type renders a touchpad, and the
/// probe's word on whether the host advertises mouse control. A catalog not
/// read refuses nothing; a host not probed grants nothing.
struct TouchpadModeFacts: Equatable {
    var typeOffersDs4 = true
    var hostMouseControl = false
}

/// The touchpad mode a descriptor asks for: the controller's pick through
/// the ladder, off while the global switch is off. The type's word is
/// whether it offers the pad render; the host's is whether it advertises
/// mouse control.
func descriptorTouchpadMode(
    _ capabilities: ControllerCapabilities,
    _ flags: ForwardingFlags,
    typeOffersDs4: Bool = true,
    hostMouseControl: Bool = false
) -> TouchpadMode {
    resolveTouchpadMode(
        pick: flags.touchpad ? flags.touchpadPick : .off,
        padHasTouchpad: capabilities.hasTouchpad,
        typeOffersDs4: typeOffersDs4,
        hostMouseControl: hostMouseControl
    )
}

/// Whether the catalog type a pad is emulated as renders a touchpad; a
/// catalog not read, or a type it does not name, refuses nothing.
func typeOffersDs4Touchpad(in catalog: CatalogDTO?, type: Int) -> Bool {
    guard let row = catalog?.controllerTypes.first(where: { $0.id == type }) else { return true }
    return typeOffersDs4Touchpad(supported: row.features.touchpad.supported, modes: row.features.touchpad.modes)
}

/// The `sdlType` values a pad family is naturally emulated as, best first.
func emulationCandidates(for family: PadFamily) -> [String] {
    switch family {
    case .dualSense: ["ps5", "ps4"]
    case .dualShock4: ["ps4", "ps5"]
    case .xbox: ["xbox360", "xboxone"]
    case .other: []
    }
}

/// The catalog type a pad is emulated as: the first candidate the catalog
/// offers under `emulates.sdlType`, else the first type offered, else the
/// legacy Xbox target when there is no catalog at all.
func preferredControllerType(in catalog: CatalogDTO?, for family: PadFamily) -> Int {
    guard let types = catalog?.controllerTypes, let first = types.first else {
        return Int(ProtocolConstants.controllerTypeXbox)
    }
    for candidate in emulationCandidates(for: family) {
        if let match = types.first(where: { $0.emulates?.sdlType == candidate }) {
            return match.id
        }
    }
    return first.id
}

// MARK: - The Emulate picker and the capability table's facts

/// Every catalog type that carries a display name is offered, even one newer
/// than this app; a nameless row is dropped. Catalog order is the order.
func offerableTypes(in catalog: CatalogDTO?) -> [PickableType] {
    (catalog?.controllerTypes ?? []).filter(isTypeOfferable).map { type in
        PickableType(id: type.id, slug: type.slug, name: type.name, shortName: type.shortName, description: type.description)
    }
}

/// Per the contract an unknown slug still renders, so the one gate is a name.
func isTypeOfferable(_ type: CatalogControllerType) -> Bool {
    !type.name.isEmpty || !type.shortName.isEmpty
}

/// The ladder: the user's override, else the type the catalog says emulates
/// the pad's family, else the first offered, else the legacy Xbox target.
func emulatedControllerType(override: Int?, catalog: CatalogDTO?, family: PadFamily) -> Int {
    override ?? preferredControllerType(in: catalog, for: family)
}

/// What the catalog says `type` carries; nil for a type the catalog does
/// not name, which leaves the type layer unresolved rather than refusing.
func typeFeatureFacts(in catalog: CatalogDTO?, type: Int) -> TypeFeatureFacts? {
    guard let row = catalog?.controllerTypes.first(where: { $0.id == type }) else { return nil }
    return TypeFeatureFacts(
        motion: row.features.motion.supported,
        touchpad: row.features.touchpad.supported,
        rumble: row.features.rumble.supported,
        lightbar: row.features.lightbar.supported,
        triggerEffects: row.features.triggerEffects.supported,
        playerLeds: row.features.playerLeds.supported,
        mic: row.features.mic.supported,
        speaker: row.features.speaker.supported,
        touchpadModes: row.features.touchpad.modes
    )
}

/// The host layer from the probe: a host feature counts when it is both
/// supported and available right now; audio is what the host's switches
/// let flow. Nil for a satellite that was never probed.
func hostProbeFacts(_ probe: ServerCapabilitiesDTO?) -> HostProbeFacts? {
    guard let probe, probe.reachable else { return nil }
    return HostProbeFacts(
        mouseControl: probe.host.mouseControl.supported && probe.host.mouseControl.available,
        rumble: probe.host.rumble.supported && probe.host.rumble.available,
        mic: probe.controllerAudio.mic,
        speaker: probe.controllerAudio.speaker
    )
}
