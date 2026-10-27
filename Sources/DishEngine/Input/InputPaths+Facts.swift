// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import Foundation

/// One carrier as the carriage rule reads it.
struct CarrierSeat: Equatable {
    let id: String
    let hasRumble: Bool
}

/// Which controller carries a Direct pad's rumble and lights, and the word
/// for its rumble.
struct OutputCarriage: Equatable {
    let carrierId: String?
    let rumble: RumbleCarriage
}

/// GameController carries a Direct pad's output only when exactly one
/// controller of the pad's kind and exactly one pad of its model are
/// connected: anything else could drive the wrong pad's motors.
func outputCarriage(model: DirectModel?, carriers: [CarrierSeat], padsOfModel: Int) -> OutputCarriage {
    guard let model, model.gameControllerCarriesOutput else { return OutputCarriage(carrierId: nil, rumble: .notCarried) }
    guard let only = carriers.first else { return OutputCarriage(carrierId: nil, rumble: .noCarrier) }
    let unambiguous = carriers.count == 1 && padsOfModel == 1
    guard unambiguous else { return OutputCarriage(carrierId: nil, rumble: .ambiguous) }
    return OutputCarriage(carrierId: only.id, rumble: only.hasRumble ? .carried : .carrierHasNoMotors)
}

/// A running check with its whole seconds left, else the last one's
/// verdict, else nothing.
func checkPhase(_ check: PadCheck?, outcome: CheckOutcome?, nowMs: Int64) -> InputCheckPhase {
    if let check { return .running(secondsLeft: checkSecondsLeft(check, nowMs: nowMs)) }
    guard let outcome else { return .idle }
    return .concluded(outcome.verdict, offer: outcome.offer)
}

/// Rounded up, so the countdown reads 5 at the start and 1 in its last second.
func checkSecondsLeft(_ check: PadCheck, nowMs: Int64) -> Int {
    let leftMs = max(InputCheckWindow.durationMs - (nowMs - check.startedAtMs), 0)
    return Int((leftMs + 999) / 1000)
}

/// The facts every forwarding pad has, whichever path it is on.
func basePathFacts(_ machine: InputSourceState, outcome: CheckOutcome?, nowMs: Int64) -> SlotInputPath? {
    guard case let .forwarding(source) = machine.phase else { return nil }
    var facts = SlotInputPath(source: source, reason: machine.reason ?? .macOSReads)
    facts.proven = machine.proven
    facts.check = checkPhase(machine.check, outcome: outcome, nowMs: nowMs)
    facts.picks = InputSource.allCases.filter(machine.canPick)
    return facts
}

/// The slot list and the return paths follow the machines, and the facts
/// follow both.
extension InputPaths {

    // MARK: - Pairing a carrier with its pad

    private func nintendoPads(productId: UInt16) -> [String] {
        pads.filter { _, pad in
            let candidate = pad.arrival?.candidate
            return candidate?.vendorId == DirectVendor.nintendo && candidate?.productId == productId
        }.keys.sorted()
    }

    private func carrierIds(productId: UInt16) -> [String] {
        carriers.filter { $0.value.productId == productId }.keys.sorted()
    }

    /// The one carrier of a Direct pad, when the pairing is sure.
    func soleCarrier(of key: String) -> PathCarrier? {
        guard let candidate = pads[key]?.arrival?.candidate, candidate.vendorId == DirectVendor.nintendo else { return nil }
        let ids = carrierIds(productId: candidate.productId)
        let sure = ids.count == 1 && nintendoPads(productId: candidate.productId).count == 1
        return sure ? ids.first.flatMap { carriers[$0] } : nil
    }

    /// The one pad a carrier belongs to, when the pairing is sure.
    func soleOwner(ofCarrier id: String) -> String? {
        guard let carrier = carriers[id] else { return nil }
        let owners = nintendoPads(productId: carrier.productId)
        let sure = owners.count == 1 && carrierIds(productId: carrier.productId).count == 1
        return sure ? owners.first : nil
    }

    func firstOwner(ofCarrier id: String) -> String? {
        carriers[id].flatMap { nintendoPads(productId: $0.productId).first }
    }

    private func carriage(of key: String) -> OutputCarriage {
        guard let candidate = pads[key]?.arrival?.candidate else { return OutputCarriage(carrierId: nil, rumble: .notCarried) }
        let seats = carrierIds(productId: candidate.productId).compactMap { id in
            carriers[id].map { CarrierSeat(id: id, hasRumble: $0.hasRumble) }
        }
        let sameModel = pads.values.filter { $0.arrival?.candidate.hardwareId == candidate.hardwareId }.count
        let nintendo = candidate.vendorId == DirectVendor.nintendo
        return outputCarriage(model: candidate.model, carriers: nintendo ? seats : [], padsOfModel: sameModel)
    }

    private func modelForwardsStandard(productId: UInt16) -> Bool {
        nintendoPads(productId: productId).contains { pads[$0]?.machine.phase == .forwarding(.standard) }
    }

    func lanesOfModel(_ productId: UInt16) -> Int {
        nintendoPads(productId: productId).count
    }

    /// A waiting carrier publishes nothing; one that fell back publishes
    /// through its stand-in machine, or, once a lane of its model joined,
    /// as the lanes' machines say, like any carrier.
    private func carrierForwards(_ id: String, _ carrier: PathCarrier) -> Bool {
        switch carrier.standing {
        case .waiting: false
        case .followsLanes: modelForwardsStandard(productId: carrier.productId)
        case .fellBack: pads[id] != nil || modelForwardsStandard(productId: carrier.productId)
        }
    }

    // MARK: - The slot list and the return paths

    /// Idempotent: every Direct lane's slot shown or hidden, every
    /// carrier's standing, input slot and gate set, every pad's output
    /// carrier named.
    func refreshOutputs() {
        for key in pads.keys.sorted() {
            showOrHide(key)
        }
        standCarriers(windowClosed: false)
        for id in carriers.keys.sorted() {
            guard let carrier = carriers[id] else { continue }
            let forwards = carrierForwards(id, carrier)
            carrier.gate.route(forwards ? .standard : nil)
            host?.showCarrierSlot(id, forwards)
        }
    }

    private func showOrHide(_ key: String) {
        guard let pad = pads[key], let lane = pad.arrival?.lane else { return }
        guard pad.machine.phase == .forwarding(.direct) else {
            host?.carryOutput(directSlotId: key, via: nil)
            host?.hideDirectSlot(key)
            return
        }
        let output = carriage(of: key)
        host?.carryOutput(directSlotId: key, via: output.carrierId)
        host?.showDirectSlot(directSlot(key, lane.candidate, output), lane: lane)
    }

    /// Motion on the Switch Pro, the battery from a Switch report, rumble
    /// and player lights only through a sure carrier.
    func directSlot(_ id: String, _ candidate: HidPadCandidate, _ output: OutputCarriage) -> GameControllerInput.Slot {
        let readsSwitchReports = if case .switchReport = candidate.decoder { true } else { false }
        let capabilities = ControllerCapabilities(
            hasMotion: candidate.model?.hasMotion ?? false,
            hasRumble: output.rumble == .carried,
            hasBattery: readsSwitchReports,
            hasPlayerLeds: output.carrierId != nil
        )
        return GameControllerInput.Slot(id: id, name: candidate.name, capabilities: capabilities, family: candidate.family)
    }

    // MARK: - The facts

    func publishFacts() {
        let nowMs = clockMs()
        var facts: [String: SlotInputPath] = [:]
        for key in pads.keys {
            facts[key] = padFacts(key, nowMs: nowMs)
        }
        for id in carriers.keys where showsInputSlot(id) {
            facts[id] = carrierFacts(id, nowMs: nowMs)
        }
        setState(facts)
    }

    /// A Direct lane has facts only while its own slot shows.
    private func padFacts(_ key: String, nowMs: Int64) -> SlotInputPath? {
        guard let pad = pads[key], var facts = basePathFacts(pad.machine, outcome: pad.outcome, nowMs: nowMs) else { return nil }
        facts.playerNumber = players.number(for: key)
        facts.keepsDisconnecting = bursts.noticed.contains(key)
        guard let candidate = pad.arrival?.candidate else { return facts }
        guard facts.source == .direct else { return nil }
        facts.rawReportHz = rawHz[key] ?? 0
        facts.layoutGuessed = candidate.layoutGuessed
        facts.remappable = readsDeclaredLayout(candidate)
        facts.rumble = carriage(of: key).rumble
        facts.transport = candidate.transport
        facts.hardwareId = candidate.hardwareId
        return facts
    }

    /// A carrier read through GameController shows its pad's machine.
    private func carrierFacts(_ id: String, nowMs: Int64) -> SlotInputPath? {
        guard let owner = machineKey(forSlot: id), let pad = pads[owner] else { return nil }
        var facts = basePathFacts(pad.machine, outcome: pad.outcome, nowMs: nowMs)
        facts?.playerNumber = players.number(for: id)
        facts?.keepsDisconnecting = bursts.noticed.contains(id)
        facts?.transport = pad.arrival?.candidate.transport
        facts?.hardwareId = pad.arrival?.candidate.hardwareId
        return facts
    }
}
