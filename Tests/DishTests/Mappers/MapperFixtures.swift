// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import DishEngine
@testable import Dish

/// The pads and hosts the controller pages' mapper tests draw.
enum MapperFixtures {
    static let den = ConnectionSummary(id: "den", name: "Den", address: "192.0.2.10", udpPort: 9876, live: .connected, boundSlotId: "pad")
    static let loft = ConnectionSummary(id: "loft", name: "Loft", address: "192.0.2.11", udpPort: 9876, live: .ready, boundSlotId: nil)
    static let host = ConnectionSummary(
        id: "moonlight:pc",
        name: "PC",
        address: "10.0.0.5",
        live: .ready,
        boundSlotId: "other",
        kind: .moonlight,
        boundSlotIds: ["other", "pad"]
    )

    static let caps = ControllerCapabilities(hasMotion: true, hasTouchpad: true, hasRumble: true, hasLightbar: true)

    static func pad(boundTo summary: ConnectionSummary? = nil) -> ControllerSlot {
        ControllerSlot(
            id: "pad",
            name: "DualSense",
            boundConnectionId: summary?.id,
            boundStatus: summary,
            capabilities: caps,
            family: .dualSense
        )
    }

    static func armedPlan(muted: Bool = false) -> AudioPlan {
        let host = HostAudioVerdict(mic: true, speaker: true, hapticAudio: true)
        return audioPlan(AudioFacts(
            routeMic: true,
            routeSpeaker: true,
            micOn: true,
            host: host,
            live: true,
            micPermitted: true,
            muted: muted
        ))
    }
}
