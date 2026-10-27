// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import Foundation

/// The pads coming and going, their input events, and the intents.
extension InputPaths {

    // MARK: - Direct lanes

    /// A Nintendo pad is connected at once and waits only for GameController's
    /// answer to the pick rules; any other pad waits for that answer first,
    /// and is left to GameController when it shows the pad.
    func hidPadArrived(_ arrival: HidPadArrival) {
        let candidate = arrival.candidate
        pads[arrival.slotId] = PathPad(arrival: arrival, name: candidate.name, gate: arrival.lane.gate)
        scheduler.after(ms: Self.devcapsDelayMs) { [weak self] in self?.logDevcaps(arrival) }
        let byModel = candidate.model?.rule == .byModel
        let fellBack = joinFallback(candidate)
        if byModel { reduce(arrival.slotId, .connected(pathFacts(candidate, support: .pending, fellBack: fellBack))) }
        settle(arrival, attempt: 1)
    }

    func pathFacts(_ candidate: HidPadCandidate, support: GameControllerSupport, fellBack: Bool = false) -> PadPathFacts {
        var facts = PadPathFacts(
            model: candidate.model,
            decodable: true,
            gameController: support,
            stored: choices.choice(vendorId: candidate.vendorId, productId: candidate.productId)
        )
        facts.fellBackToStandard = fellBack
        return facts
    }

    /// A lane replaced under the same id ends the old one's checks.
    private func settle(_ arrival: HidPadArrival, attempt: Int) {
        guard pads[arrival.slotId]?.arrival?.lane === arrival.lane else { return }
        switch settledSupport(supported: arrival.probe.supports(), attempt: attempt) {
        case .pending: scheduler.after(ms: GameControllerSettle.intervalMs) { [weak self] in self?.settle(arrival, attempt: attempt + 1) }
        case .shows: supportSettled(arrival, shows: true)
        case .doesNotShow: supportSettled(arrival, shows: false)
        }
    }

    private func supportSettled(_ arrival: HidPadArrival, shows: Bool) {
        let byModel = arrival.candidate.model?.rule == .byModel
        if byModel {
            reduce(arrival.slotId, .gameControllerResolved(shows: shows))
        } else if shows {
            leaveToGameController(arrival)
        } else {
            reduce(arrival.slotId, .connected(pathFacts(arrival.candidate, support: .doesNotShow)))
        }
    }

    private func leaveToGameController(_ arrival: HidPadArrival) {
        pads.removeValue(forKey: arrival.slotId)
        reader.release(slotId: arrival.slotId)
        Self.log.info("DIRECT released id=\(arrival.slotId, privacy: .public): GameController reads it")
    }

    /// Measured on the reader's thread, logged here once per attach of a
    /// lane still read.
    private func logDevcaps(_ arrival: HidPadArrival) {
        guard pads[arrival.slotId]?.arrival?.lane === arrival.lane else { return }
        let candidate = arrival.candidate
        let tally = arrival.lane.tally.snapshot()
        let firstMs = tally.firstReportMs.map(String.init) ?? "none"
        let vidpid = usbPathKey(vendorId: candidate.vendorId, productId: candidate.productId)
        let line = """
        DEVCAPS DIRECT id=\(arrival.slotId) vidpid=\(vidpid) transport=\(transportWord(candidate.transport)) \
        kind=\(laneKindWord(candidate.decoder)) name=\(candidate.name) firstReportMs=\(firstMs) \
        reportsFirstSecond=\(tally.reportsFirstSecond)
        """
        Self.log.info("\(line, privacy: .public)")
    }

    func hidPadRemoved(slotId: String) {
        guard let name = pads[slotId]?.arrival?.candidate.name else { return }
        reduce(slotId, .disconnected)
        pads.removeValue(forKey: slotId)
        rawRates.removeValue(forKey: slotId)
        rawHz.removeValue(forKey: slotId)
        host?.hideDirectSlot(slotId)
        recordDrop(slotId, name: name)
        refreshOutputs()
        publishFacts()
    }

    // MARK: - GameController's controllers

    /// The gate the controller's handlers read. A controller GameController
    /// lists under a Direct-by-model category becomes a carrier; any other
    /// is a pad of its own, read through GameController.
    func gameControllerAttached(id: String, name: String, category: String, hasRumble: Bool) -> PadGate {
        if let existing = pads[id]?.gate ?? carriers[id]?.gate { return existing }
        let gate = makeGate(key: id)
        if let model = directModel(gameControllerCategory: category) {
            carriers[id] = PathCarrier(productId: model.productId, name: name, gate: gate, hasRumble: hasRumble)
            scheduler.after(ms: CarrierFallbackRule.settleMs) { [weak self] in self?.carrierWindowClosed(id, gate: gate) }
            refreshOutputs()
            raiseCarrierAttention(id)
            publishFacts()
            return gate
        }
        pads[id] = PathPad(arrival: nil, name: name, gate: gate)
        reduce(id, .connected(PadPathFacts(model: nil, decodable: false, gameController: .shows, stored: nil)))
        return gate
    }

    /// A carrier that arrives while its pad waits for events hears for it too.
    private func raiseCarrierAttention(_ id: String) {
        guard let owner = soleOwner(ofCarrier: id), let machine = pads[owner]?.machine, wantsInputEvents(machine) else { return }
        carriers[id]?.gate.requestEvents()
    }

    func gameControllerDetached(id: String, name: String) {
        if let carrier = carriers.removeValue(forKey: id) {
            let visible = carrier.gate.routed == .standard
            carrier.gate.route(nil)
            retireFallbackPad(id)
            if visible { recordDrop(id, name: name) }
            refreshOutputs()
            publishFacts()
            return
        }
        guard pads[id] != nil else { return }
        reduce(id, .disconnected)
        pads.removeValue(forKey: id)
        recordDrop(id, name: name)
        publishFacts()
    }

    /// Whether the controller's own input slot shows.
    func showsInputSlot(_ gameControllerId: String) -> Bool {
        guard let carrier = carriers[gameControllerId] else { return true }
        return carrier.gate.routed == .standard
    }

    // MARK: - Input events

    /// A carrier's change belongs to its pad only when the pairing is sure.
    func inputChanged(gateKey: String, source: InputSource) {
        let nowMs = clockMs()
        let key = pads[gateKey] != nil ? gateKey : soleOwner(ofCarrier: gateKey)
        guard let key else { return }
        switch source {
        case .standard: reduce(key, .standardInputChanged(nowMs: nowMs))
        case .direct: reduce(key, .directInputChanged(nowMs: nowMs))
        }
    }

    // MARK: - Intents

    /// The pad's machine: its own, or, for a carrier, its sole pad's.
    func machineKey(forSlot slotId: String) -> String? {
        if pads[slotId] != nil { return slotId }
        return carriers[slotId] == nil ? nil : soleOwner(ofCarrier: slotId) ?? firstOwner(ofCarrier: slotId)
    }

    func startCheck(slotId: String) {
        guard let key = machineKey(forSlot: slotId) else { return }
        pads[key]?.outcome = nil
        reduce(key, .checkStarted(nowMs: clockMs()))
        armCheckTicks()
    }

    /// Honoured only where the path is available; a pick moves every
    /// connected pad of the model, since the choice is the model's.
    func pick(slotId: String, _ source: InputSource) -> Bool {
        guard let key = machineKey(forSlot: slotId), let pad = pads[key], pad.machine.canPick(source) else { return false }
        let model = pad.arrival.map(\.candidate.hardwareId)
        let sameModel = pads.filter { $0.value.arrival.map(\.candidate.hardwareId) == model && model != nil }.keys.sorted()
        for each in sameModel.isEmpty ? [key] : sameModel {
            reduce(each, .userPicked(source))
        }
        return true
    }

    private func armCheckTicks() {
        guard checkTimer == nil else { return }
        checkTimer = scheduler.every(ms: Self.checkTickMs) { [weak self] in self?.tick() }
    }

    /// The checks' clock; it stops with the last check.
    func tick() {
        let nowMs = clockMs()
        let checking = pads.filter { $0.value.machine.check != nil }.keys.sorted()
        for key in checking {
            reduce(key, .tick(nowMs: nowMs))
        }
        let stillChecking = pads.values.contains { $0.machine.check != nil }
        guard !stillChecking else { return }
        checkTimer?.cancel()
        checkTimer = nil
    }

    // MARK: - Players, drops and rates

    /// The slot list's ids as it stands: arrivals take the lowest free number.
    func slotsChanged(_ ids: [String]) {
        let present = Set(ids)
        for gone in players.numbers.keys where !present.contains(gone) {
            // The freed number is not needed: the next connect takes the lowest free one.
            _ = players.disconnect(gone)
        }
        for id in ids {
            // The number is read back with the facts.
            _ = players.connect(id)
        }
        publishFacts()
    }

    func recordDrop(_ identity: String, name: String) {
        let startsBurst = bursts.recordDrop(identity, nowMs: clockMs())
        guard startsBurst else { return }
        Self.log.info("DISCONNECTS id=\(identity, privacy: .public): three drops within a minute")
        records.send(InputPathRecord(subject: name, note: .keepsDisconnecting))
    }

    /// The facts of one visible slot, for a reader that asks by id.
    func facts(forSlot slotId: String) -> SlotInputPath? {
        state[slotId]
    }

    /// The raw rates against the uptime clock, for the ticks that already run.
    func sampleRawRatesNow() {
        sampleRawRates(nowUs: uptimeUs())
    }

    /// The Direct lanes' raw counts as rates, on a tick that already runs.
    func sampleRawRates(nowUs: UInt64) {
        for (key, pad) in pads {
            guard let lane = pad.arrival?.lane else { continue }
            let count = lane.tally.snapshot().reports
            rawHz[key] = rawRates[key, default: InputRateTracker()].sample(count: count, nowUs: nowUs)
        }
        publishFacts()
    }
}

/// IOKit's transport in a DEVCAPS line.
func transportWord(_ transport: HidTransport) -> String {
    switch transport {
    case .usb: "usb"
    case .bluetooth: "bluetooth"
    case let .other(word): word
    case .unknown: "unknown"
    }
}
