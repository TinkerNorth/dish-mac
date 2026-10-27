// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import Foundation

/// "Check the buttons" and "Help support this controller" reach the pads
/// through the paths, which know each slot's lane.
extension InputPaths {

    /// The walk over the slot's lane, or the word for why there is none.
    func beginButtonCheck(slotId: String) {
        let present = pads[slotId] != nil || carriers[slotId] != nil
        let name = pads[slotId]?.name ?? carriers[slotId]?.name ?? ""
        buttonCheck.begin(slotId: slotId, name: name, lane: pads[slotId]?.arrival?.lane, present: present)
    }

    /// Every lane reads its model's table from the remaps as they now are:
    /// the store publishes them before it holds them.
    func remapsChanged(_ stored: [String: JoystickRemap]) {
        for pad in pads.values {
            guard let lane = pad.arrival?.lane else { continue }
            lane.useRemap(remapTable(for: lane.candidate, in: stored))
        }
    }

    func makeCapturePost() -> @Sendable (String, RawCapture) -> Void {
        { [relay] slotId, capture in
            DispatchQueue.main.async { MainActor.assumeIsolated { relay.paths?.buttonCheck.captured(slotId: slotId, capture) } }
        }
    }
}

/// A generic pad read through its descriptor, not a fixed decoder.
func readsDeclaredLayout(_ candidate: HidPadCandidate) -> Bool {
    if case .hidGamepad = candidate.decoder { return true }
    return false
}
