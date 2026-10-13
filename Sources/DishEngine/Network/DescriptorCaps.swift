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
/// Analog triggers ride every extended gamepad. The audio caps stay off
/// until this client carries controller audio.
func descriptorCaps(_ capabilities: ControllerCapabilities, _ flags: ForwardingFlags) -> UInt16 {
    let claims: [(claimed: Bool, bit: UInt16)] = [
        (true, ProtocolConstants.capAnalogTriggers),
        (capabilities.hasRumble && flags.rumble, ProtocolConstants.capRumble),
        (capabilities.hasMotion && flags.motion, ProtocolConstants.capMotion),
        (capabilities.hasLightbar && flags.lightbar, ProtocolConstants.capLightbar),
        (capabilities.hasTriggerEffects, ProtocolConstants.capTriggerEffects),
        (capabilities.hasPlayerLeds, ProtocolConstants.capPlayerLeds)
    ]
    return claims.filter(\.claimed).reduce(UInt16(0)) { $0 | $1.bit }
}

/// The touchpad mode a descriptor asks for: the pad render when the pad has
/// a touchpad and the switch is on, else off. Host mouse control is a later
/// surface.
func descriptorTouchpadMode(_ capabilities: ControllerCapabilities, _ flags: ForwardingFlags) -> TouchpadMode {
    capabilities.hasTouchpad && flags.touchpad ? .ds4 : .off
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
