// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import Foundation

/// An opt-in model Dish could read directly, on the Controllers page until a
/// pad of it is read there. A wireless receiver's slots make one offer.
package struct DirectOffer: Equatable, Identifiable {
    /// A lane of the model: the intents go through it, and a pick moves
    /// every lane of the model.
    package let id: String
    package let name: String
    package let standing: DirectOfferStanding

    package init(id: String, name: String, standing: DirectOfferStanding) {
        self.id = id
        self.name = name
        self.standing = standing
    }
}

package enum DirectOfferStanding: Equatable {
    /// Dish reads it once the user picks Direct; macOS asks for Input
    /// Monitoring first when the pad's interface also carries its keyboard.
    case offered(asksInputMonitoring: Bool)
    /// The user picked Direct and macOS would not let Dish open it.
    case refused(ClaimRefusal)
    /// Dish reads the receiver, and no controller has connected to it yet.
    case waitingForController
}

/// What a model's lanes amount to, for its offer.
struct OfferLanes: Equatable {
    /// A lane is a pad on the page.
    var shown = false
    var refusal: ClaimRefusal?
    var offered = false
    var asksInputMonitoring = false
    /// A lane is read, its controller not there yet.
    var reading = false
}

/// None once a lane is a pad on the page; a refusal before the offer, and
/// the offer before a receiver waiting for its controller.
func offerStanding(_ lanes: OfferLanes) -> DirectOfferStanding? {
    if lanes.shown { return nil }
    if let refusal = lanes.refusal { return .refused(refusal) }
    if lanes.offered { return .offered(asksInputMonitoring: lanes.asksInputMonitoring) }
    return lanes.reading ? .waitingForController : nil
}

extension InputPaths {

    /// One offer per opt-in model, ordered by the lane that speaks for it.
    func directOffers() -> [DirectOffer] {
        let lanes = pads.keys.filter(readsOnClaim).sorted()
        let byModel = Dictionary(grouping: lanes) { pads[$0]?.arrival?.candidate.hardwareId }
        return byModel.values.compactMap(modelOffer).sorted { $0.id < $1.id }
    }

    private func modelOffer(_ keys: [String]) -> DirectOffer? {
        let sorted = keys.sorted()
        guard let first = sorted.first, let candidate = pads[first]?.arrival?.candidate else { return nil }
        guard let standing = offerStanding(offerLanes(sorted)) else { return nil }
        return DirectOffer(id: first, name: candidate.name, standing: standing)
    }

    private func offerLanes(_ keys: [String]) -> OfferLanes {
        var lanes = OfferLanes()
        lanes.shown = keys.contains(where: showsDirectSlot)
        lanes.refusal = keys.lazy.compactMap { self.refusals[$0] }.first
        lanes.offered = keys.contains { pads[$0]?.machine.phase == .offered }
        lanes.asksInputMonitoring = keys.contains { pads[$0]?.arrival?.candidate.needsInputMonitoring == true }
        lanes.reading = keys.contains { pads[$0]?.machine.phase == .forwarding(.direct) }
        return lanes
    }
}
