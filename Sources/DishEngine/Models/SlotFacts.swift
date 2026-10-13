// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// The facts a bound slot carries for the UI beyond its binding: the type it
// is emulated as and the types it could be, what that type and the host
// carry, and the host's word on motion. Data only; the app solves and words.

import DishCore
import Foundation

/// A binding's identity for the per-slot stores: the satellite and the pad.
package struct SlotKey: Hashable {
    package let connectionId: String
    package let slotId: String

    package init(connectionId: String, slotId: String) {
        self.connectionId = connectionId
        self.slotId = slotId
    }
}

/// One row the Emulate picker renders. The display strings are the
/// satellite's and already localized; an unknown slug still renders from
/// them, so a type newer than this app is offered too.
package struct PickableType: Hashable {
    package let id: Int
    package let slug: String
    package let name: String
    package let shortName: String
    package let description: String

    package init(id: Int, slug: String, name: String, shortName: String, description: String) {
        self.id = id
        self.slug = slug
        self.name = name
        self.shortName = shortName
        self.description = description
    }

    /// The short name where the catalog gives one, else the name.
    package var label: String {
        shortName.isEmpty ? name : shortName
    }
}

/// How a bound slot is emulated: the resolved type, whether the user chose
/// it, and the types the satellite offers in its place.
package struct SlotEmulation: Hashable {
    package let type: Int
    package let isOverride: Bool
    package let offered: [PickableType]

    package init(type: Int, isOverride: Bool, offered: [PickableType]) {
        self.type = type
        self.isOverride = isOverride
        self.offered = offered
    }

    /// The offered row for the resolved type; nil for a type the catalog
    /// does not name, which the picker then shows by number.
    package var current: PickableType? {
        offered.first { $0.id == type }
    }
}

/// What the resolved catalog type carries, for the type layer of the
/// capability table. Nil until the catalog is read.
package struct TypeFeatureFacts: Hashable {
    package let motion: Bool
    package let touchpad: Bool
    package let rumble: Bool
    package let lightbar: Bool
    package let triggerEffects: Bool
    package let playerLeds: Bool
    package let mic: Bool
    package let speaker: Bool

    package init(
        motion: Bool, touchpad: Bool, rumble: Bool, lightbar: Bool,
        triggerEffects: Bool, playerLeds: Bool, mic: Bool, speaker: Bool
    ) {
        self.motion = motion
        self.touchpad = touchpad
        self.rumble = rumble
        self.lightbar = lightbar
        self.triggerEffects = triggerEffects
        self.playerLeds = playerLeds
        self.mic = mic
        self.speaker = speaker
    }
}

/// What the satellite carries right now, from its capabilities probe, for
/// the host layer of the capability table. Nil until the probe is read.
package struct HostProbeFacts: Hashable {
    package let mouseControl: Bool
    package let rumble: Bool
    package let mic: Bool
    package let speaker: Bool

    package init(mouseControl: Bool, rumble: Bool, mic: Bool, speaker: Bool) {
        self.mouseControl = mouseControl
        self.rumble = rumble
        self.mic = mic
        self.speaker = speaker
    }
}

/// The satellite's word on a slot's motion, from the apply result: whether
/// the host has a motion sink for the slot's type and whether its motion
/// backend is healthy. Both must hold for motion to land.
package struct MotionBackendStatus: Hashable {
    package let sinkSupportedForType: Bool
    package let backendOk: Bool

    package init(sinkSupportedForType: Bool, backendOk: Bool) {
        self.sinkSupportedForType = sinkSupportedForType
        self.backendOk = backendOk
    }

    package var effective: Bool {
        sinkSupportedForType && backendOk
    }
}
