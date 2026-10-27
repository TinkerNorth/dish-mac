// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import Foundation

/// A carrier Dish's reader never found a lane for: after the settle window
/// it is read through GameController under a stand-in machine of its own,
/// so its pad is proven, checked and numbered like any other; a lane of its
/// model that turns up later takes the machine over on Standard.
extension InputPaths {

    /// The settle window closed on the carrier that arrived with `gate`.
    func carrierWindowClosed(_ id: String, gate: PadGate) {
        guard carriers[id]?.gate === gate else { return }
        standCarriers(only: id, windowClosed: true)
        refreshOutputs()
        publishFacts()
    }

    /// Every carrier's standing, or one's, against the lanes there now; a
    /// carrier that fell back with no lane of its model gets its stand-in.
    func standCarriers(only: String? = nil, windowClosed: Bool) {
        for id in carriers.keys.sorted() where only == nil || only == id {
            guard var carrier = carriers[id] else { continue }
            let lanes = lanesOfModel(carrier.productId)
            carrier.standing = standCarrier(carrier.standing, lanesOfModel: lanes, windowClosed: windowClosed)
            carriers[id] = carrier
            let needsStandIn = carrier.standing == .fellBack && lanes == 0 && pads[id] == nil
            if needsStandIn { adoptFallenBack(id, carrier) }
        }
    }

    /// The stand-in: the model's own decision with GameController reading
    /// the pad, and no decoder of Dish's behind it.
    private func adoptFallenBack(_ id: String, _ carrier: PathCarrier) {
        let model = directModel(vendorId: DirectVendor.nintendo, productId: carrier.productId)
        let stored = choices.choice(vendorId: DirectVendor.nintendo, productId: carrier.productId)
        var facts = PadPathFacts(model: model, decodable: false, gameController: .shows, stored: stored)
        facts.fellBackToStandard = true
        pads[id] = PathPad(arrival: nil, name: carrier.name, gate: carrier.gate)
        Self.log.info("FALLBACK id=\(id, privacy: .public): no Direct lane of its model in time")
        reduce(id, .connected(facts))
    }

    /// A lane of a model whose carrier fell back joins it on Standard: the
    /// stand-in gives way to the lane's machine, and nothing is rerouted.
    func joinFallback(_ candidate: HidPadCandidate) -> Bool {
        guard candidate.vendorId == DirectVendor.nintendo else { return false }
        let fallen = carriers.filter { $0.value.productId == candidate.productId && $0.value.standing == .fellBack }.keys
        for id in fallen {
            pads.removeValue(forKey: id)
        }
        return !fallen.isEmpty
    }

    /// The carrier left: its stand-in ends with it.
    func retireFallbackPad(_ id: String) {
        guard pads[id]?.arrival == nil, pads[id] != nil else { return }
        reduce(id, .disconnected)
        pads.removeValue(forKey: id)
    }
}
