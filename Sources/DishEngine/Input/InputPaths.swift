// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// Each pad's input source, driven on the main actor: one input-source
// machine per pad (a Direct pad the HID reader opened, or a pad
// GameController reads), its effects run against the pad's hot-path gate,
// the slot list and the stored picks, and the facts the cards and
// Diagnostics read, keyed by the slot id the UI shows.

import Combine
import DishCore
import DishKernel
import Foundation
import os

// MARK: - What the UI reads

/// Where a pad's "Not responding?" check stands.
package enum InputCheckPhase: Equatable {
    case idle
    case running(sinceMs: Int64)
    case concluded(CheckVerdict, offer: CheckOffer)
}

/// Why a pad's rumble works or does not.
package enum RumbleCarriage: Equatable {
    /// GameController reads the pad and drives its motors itself.
    case ownController
    /// GameController's controller for the pad carries Dish's rumble.
    case carried
    /// The one controller GameController shows for the pad has no motors.
    case carrierHasNoMotors
    /// GameController shows no controller of the pad's kind.
    case noCarrier
    /// More than one controller or more than one pad of the kind is
    /// connected, so which carries which is unknown.
    case ambiguous
    /// Dish sends nothing back to this model.
    case notCarried
}

/// One visible slot's input path.
package struct SlotInputPath: Equatable {
    package var source: InputSource
    package var reason: InputSourceReason
    /// A real input change has arrived on the forwarded source.
    package var proven = false
    package var check = InputCheckPhase.idle
    /// The paths the user may move the pad onto now.
    package var picks: [InputSource] = []
    /// Reports per second off the wire, for a Direct pad.
    package var rawReportHz: Int?
    package var layoutGuessed = false
    package var rumble = RumbleCarriage.ownController
    /// The pad dropped three times within a minute.
    package var keepsDisconnecting = false
    package var playerNumber: Int?
    package var transport: HidTransport?
    package var hardwareId: HidHardwareId?

    package init(source: InputSource, reason: InputSourceReason) {
        self.source = source
        self.reason = reason
    }
}

/// One line for the flight recorder: the pad, and what was decided.
package struct InputPathRecord: Equatable {
    package let subject: String
    package let note: PadPathNote

    package init(subject: String, note: PadPathNote) {
        self.subject = subject
        self.note = note
    }
}

// MARK: - Seams

/// What the paths do to the slot list and the return paths.
@MainActor
protocol InputPathHost: AnyObject {
    /// A Direct pad's slot, shown or updated.
    func showDirectSlot(_ slot: GameControllerInput.Slot, lane: HidPadLane)
    func hideDirectSlot(_ slotId: String)
    /// A Nintendo-category controller's own input slot, shown only while
    /// its model is read through GameController.
    func showCarrierSlot(_ gameControllerId: String, _ shown: Bool)
    /// The controller a Direct pad's rumble and player lights ride, or none.
    func carryOutput(directSlotId: String, via gameControllerId: String?)
    func directBatteryChanged(_ slotId: String, _ battery: PadBattery)
}

/// A repeating main-actor timer.
@MainActor
protocol InputPathTimer: AnyObject {
    func cancel()
}

/// The main actor's clocks, a seam so a test moves time by hand.
@MainActor
protocol InputPathScheduler: AnyObject {
    func after(ms: Int, _ work: @escaping @MainActor () -> Void)
    func every(ms: Int, _ work: @escaping @MainActor () -> Void) -> InputPathTimer
}

// MARK: - The pads

/// A pad with a machine: a Direct lane, or a controller GameController reads.
struct PathPad {
    /// The lane the reader opened; nil for a GameController pad.
    let arrival: HidPadArrival?
    let name: String
    let gate: PadGate
    var machine = InputSourceState.initial
    var outcome: CheckOutcome?
}

struct CheckOutcome: Equatable {
    let verdict: CheckVerdict
    let offer: CheckOffer
}

/// A controller GameController shows for a Direct-by-model pad: no input
/// slot of its own unless its model is picked Standard, and the carrier of
/// the pad's rumble and lights when the pairing is unambiguous.
struct PathCarrier {
    let productId: UInt16
    let gate: PadGate
    let hasRumble: Bool
}

@MainActor
final class InputPaths: StateSource<[String: SlotInputPath]> {
    static let log = Logger(subsystem: "com.tinkernorth.dish", category: "Direct")
    static let checkTickMs = 1000
    /// The DEVCAPS DIRECT line waits for the first second's count.
    static let devcapsDelayMs = 1050

    /// Every path decision, check verdict and disconnect burst.
    let records = PassthroughSubject<InputPathRecord, Never>()
    weak var host: InputPathHost?

    let choices: UsbPathChoiceStore
    let reader: HidPadReading
    let scheduler: InputPathScheduler
    let clockMs: () -> Int64
    var pads: [String: PathPad] = [:]
    var carriers: [String: PathCarrier] = [:]
    var players = PlayerNumbers()
    var bursts = DisconnectBursts()
    var rawRates: [String: InputRateTracker] = [:]
    var rawHz: [String: Int] = [:]
    var checkTimer: InputPathTimer?
    /// What the other threads' posts reach the paths through.
    private let relay = PathsRelay()

    init(
        choices: UsbPathChoiceStore,
        reader: HidPadReading = InertHidPadReader(),
        scheduler: InputPathScheduler = LiveInputPathScheduler(),
        clockMs: @escaping () -> Int64 = uptimeMs
    ) {
        self.choices = choices
        self.reader = reader
        self.scheduler = scheduler
        self.clockMs = clockMs
        super.init(initial: [:])
        relay.paths = self
    }

    /// The reader starts once the processor it publishes into exists.
    func start(processor: GamepadInputProcessor) {
        let wiring = HidPadWiring(processor: processor, notify: makeNotify(), battery: makeBatteryPost())
        reader.start(wiring: wiring, events: HidPadEvents(arrived: makeArrivalPost(), removed: makeRemovalPost()))
    }

    /// A gate for a pad's hot path that posts its events here.
    func makeGate(key: String) -> PadGate {
        PadGate(key: key, notify: makeNotify())
    }

    // MARK: - Hops to the main actor

    private func makeNotify() -> PadGate.Notify {
        { [relay] key, source in
            DispatchQueue.main.async { MainActor.assumeIsolated { relay.paths?.inputChanged(gateKey: key, source: source) } }
        }
    }

    private func makeBatteryPost() -> @Sendable (String, PadBattery) -> Void {
        { [relay] slotId, battery in
            DispatchQueue.main.async { MainActor.assumeIsolated { relay.paths?.host?.directBatteryChanged(slotId, battery) } }
        }
    }

    private func makeArrivalPost() -> @Sendable (HidPadArrival) -> Void {
        { [relay] arrival in
            DispatchQueue.main.async { MainActor.assumeIsolated { relay.paths?.hidPadArrived(arrival) } }
        }
    }

    private func makeRemovalPost() -> @Sendable (String) -> Void {
        { [relay] slotId in
            DispatchQueue.main.async { MainActor.assumeIsolated { relay.paths?.hidPadRemoved(slotId: slotId) } }
        }
    }

    // MARK: - The machine

    /// One event through the pad's machine, its effects run, the hot path's
    /// bits brought in line and the facts republished.
    func reduce(_ key: String, _ event: InputSourceEvent) {
        guard var pad = pads[key] else { return }
        let before = pad.machine
        let reduction = reduceInputSource(before, event)
        pad.machine = reduction.next
        pads[key] = pad
        for effect in reduction.effects {
            run(effect, key: key)
        }
        syncAttention(key, before: before)
        publishFacts()
    }

    private func run(_ effect: InputSourceEffect, key: String) {
        switch effect {
        case let .forward(source): forwarded(key, source)
        case .stopForwarding: pads[key]?.gate.route(nil)
        case let .remember(source): remember(key, source)
        case let .verdict(verdict, offer): concluded(key, CheckOutcome(verdict: verdict, offer: offer))
        }
    }

    private func forwarded(_ key: String, _ source: InputSource) {
        guard let pad = pads[key] else { return }
        let reason = pad.machine.reason ?? .macOSReads
        pad.gate.route(source)
        let line = "PATH id=\(key) source=\(source.rawValue) reason=\(reason)"
        Self.log.info("\(line, privacy: .public)")
        records.send(InputPathRecord(subject: pad.name, note: .chosen(source, reason)))
        guard pad.arrival != nil else { return }
        refreshOutputs()
    }

    private func remember(_ key: String, _ source: InputSource) {
        guard let candidate = pads[key]?.arrival?.candidate else { return }
        choices.setChoice(source, vendorId: candidate.vendorId, productId: candidate.productId)
    }

    private func concluded(_ key: String, _ outcome: CheckOutcome) {
        guard let pad = pads[key] else { return }
        pads[key]?.outcome = outcome
        Self.log.info("CHECK id=\(key, privacy: .public) verdict=\(String(describing: outcome.verdict), privacy: .public)")
        records.send(InputPathRecord(subject: pad.name, note: .verdict(outcome.verdict)))
    }

    /// The bits go up when the pad starts forwarding, when a check starts or
    /// ends with the pad still unproven, and come down once the machine
    /// needs no event. An event alone never raises them again, so a check
    /// hears each source at most once.
    private func syncAttention(_ key: String, before: InputSourceState) {
        guard let after = pads[key]?.machine else { return }
        let gates = attentionGates(key)
        let wants = wantsInputEvents(after)
        guard wants else {
            gates.forEach { $0.cancelEvents() }
            return
        }
        let movedSource = before.phase != after.phase
        let checkBegan = before.check == nil && after.check != nil
        let checkEnded = before.check != nil && after.check == nil
        let raise = movedSource || checkBegan || checkEnded
        guard raise else { return }
        gates.forEach { $0.requestEvents() }
    }

    /// A Direct lane hears GameController's side through its carriers.
    func attentionGates(_ key: String) -> [PadGate] {
        guard let pad = pads[key] else { return [] }
        let carrier = soleCarrier(of: key)?.gate
        return [pad.gate] + [carrier].compactMap(\.self)
    }
}

/// The paths, weakly, for a closure another thread runs: the reference is
/// read only once the closure has hopped to the main actor.
final class PathsRelay: @unchecked Sendable {
    weak var paths: InputPaths?
}

/// A forwarding pad needs events until a real change proves it, and while a
/// check runs.
func wantsInputEvents(_ state: InputSourceState) -> Bool {
    guard case .forwarding = state.phase else { return false }
    return !state.proven || state.check != nil
}

// MARK: - The live clocks

@MainActor
final class LiveInputPathScheduler: InputPathScheduler {
    nonisolated init() {}

    func after(ms: Int, _ work: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(ms)) { MainActor.assumeIsolated(work) }
    }

    func every(ms: Int, _ work: @escaping @MainActor () -> Void) -> InputPathTimer {
        LiveInputPathTimer(ms: ms, work: work)
    }
}

@MainActor
final class LiveInputPathTimer: InputPathTimer {
    private let source: DispatchSourceTimer

    init(ms: Int, work: @escaping @MainActor () -> Void) {
        source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(deadline: .now() + .milliseconds(ms), repeating: .milliseconds(ms))
        source.setEventHandler { MainActor.assumeIsolated(work) }
        source.resume()
    }

    func cancel() {
        source.cancel()
    }
}
