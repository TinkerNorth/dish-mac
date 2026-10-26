// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Combine
import DishCore
import Foundation

/// What the Configure binding page draws: the draft it edits, the pad as
/// the draft would bind it (what the type picker and the "What carries"
/// table read), and the one apply's progress.
package struct BindingFacts: Equatable {
    package var draft: BindingDraft?
    package var candidate: ControllerSlot?
    package var progress = ApplyProgress.idle
    /// What the apply in flight replaced, for a cancel to put back.
    var replaced: BindingChoice?

    package init() {}
}

/// The Configure binding page's intents: every edit lands in the draft, and
/// the one apply writes the binding, the type and the switches together,
/// then follows the host until it carries the pad, refuses it, or the
/// budget runs out. A Moonlight binding is a durable intent and is done at
/// once; a satellite without a session is reached for and may be cancelled
/// back to what was there until its link comes up.
package extension AppModel {

    internal func observeBindingFacts() {
        $slots
            .sink { [weak self] slots in self?.refreshCandidate(slots: slots) }
            .store(in: &cancellables)
    }

    internal func openBindingDraft(slotId: String) {
        shellFacts.binding.draft = BindingDraft(slotId: slotId, original: currentChoice(slotId))
        settleEndedApply()
        refreshCandidate(slots: slots)
    }

    /// Another page's draft becomes the one the candidate and the apply read.
    internal func adoptBindingDraft(_ draft: BindingDraft?) {
        shellFacts.binding.draft = draft
        refreshCandidate(slots: slots)
    }

    internal func closeBindingDraft() {
        shellFacts.binding.draft = nil
        shellFacts.binding.candidate = nil
        settleEndedApply()
    }

    func editBinding(_ event: BindingDraftEvent) {
        guard let draft = shellFacts.binding.draft else { return }
        shellFacts.binding.draft = reduce(draft, event)
        refreshCandidate(slots: slots)
    }

    func applyBinding(_ draft: BindingDraft) {
        guard canApply(draft), let connectionId = draft.current.connectionId else { return }
        guard !applyInFlight(shellFacts.binding.progress) else { return }
        let attached = input.slots.contains { $0.id == draft.slotId }
        guard attached else { return advanceApply(.padGone) }
        let path = applyPath(connectionId)
        let boundHere = hub.bindings[draft.slotId] == connectionId
        shellFacts.binding.replaced = currentChoice(draft.slotId)
        write(draft.current, slotId: draft.slotId)
        advanceApply(.started(path))
        follow(path, slotId: draft.slotId, connectionId: connectionId, boundHere: boundHere)
    }

    /// Honoured only while the binding waits for its link: what was there
    /// before the apply is written back.
    func cancelApply() {
        guard applyCancellable(shellFacts.binding.progress), let replaced = shellFacts.binding.replaced,
              let slotId = shellFacts.binding.draft?.slotId else { return }
        bindingWatch.end()
        write(replaced, slotId: slotId)
        advanceApply(.cancelled)
    }

    func dismissApply() {
        advanceApply(.dismissed)
    }

    /// The page's Unbind: the pad lets go and the draft starts over from no binding.
    func unbindFromDraft() {
        guard let slotId = shellFacts.binding.draft?.slotId else { return }
        unbind(slotId: slotId)
        openBindingDraft(slotId: slotId)
    }

    // MARK: - The draft's seed and candidate

    internal func currentChoice(_ slotId: String) -> BindingChoice {
        let switches = slotPreferences.preferences(for: slotId)
        let connectionId = hub.bindings[slotId]
        let type = connectionId.flatMap { wifi.typeOverrides.typeFor(SlotKey(connectionId: $0, slotId: slotId)) }
        return BindingChoice(
            connectionId: connectionId,
            emulatedType: type,
            motion: switches.motion,
            rumble: switches.rumble,
            touchpad: switches.touchpad,
            mic: switches.mic,
            speaker: switches.speaker
        )
    }

    private func refreshCandidate(slots: [ControllerSlot]) {
        let draft = shellFacts.binding.draft
        let pad = draft.flatMap { draft in input.slots.first { $0.id == draft.slotId } }
        guard let draft, let pad else { return shellFacts.binding.candidate = nil }
        shellFacts.binding.candidate = candidateSlot(pad, draft.current, slots: slots)
    }

    /// The pad as the choice would bind it: the slot's own facts, the
    /// choice's switches, and the destination's catalog, probe and type.
    private func candidateSlot(_ pad: GameControllerInput.Slot, _ choice: BindingChoice, slots: [ControllerSlot]) -> ControllerSlot {
        let listed = slots.first { $0.id == pad.id }
        var slot = ControllerSlot(id: pad.id, name: pad.name, capabilities: listed?.capabilities ?? pad.capabilities, family: pad.family)
        slot.battery = listed?.battery
        slot.audioRoute = listed?.audioRoute
        slot.preferences = SlotPreferences(choice)
        guard let connectionId = choice.connectionId else { return slot }
        slot.boundConnectionId = connectionId
        slot.boundStatus = hub.summary(connectionId)
        attachBindingFacts(to: &slot, gc: pad, connectionId: connectionId, facts: candidateFacts(choice, slotId: pad.id))
        return slot
    }

    private func candidateFacts(_ choice: BindingChoice, slotId: String) -> SlotFactsSnapshot {
        var facts = SlotFactsSnapshot()
        facts.catalogs = wifi.catalogs
        facts.probes = wifi.capabilities
        facts.motion = wifi.motionStatus.state
        facts.moonlightHostTypes = Dictionary(uniqueKeysWithValues: moonlight.rememberedHosts.map { ($0.id, $0.emulatedType) })
        if let connectionId = choice.connectionId, let type = choice.emulatedType {
            facts.overrides[SlotKey(connectionId: connectionId, slotId: slotId)] = type
        }
        return facts
    }

    // MARK: - Writing a choice

    /// The switches first, then the type, then the binding, so the bind
    /// already carries the type the choice names.
    private func write(_ choice: BindingChoice, slotId: String) {
        writeSwitches(choice, slotId: slotId)
        guard let connectionId = choice.connectionId else { return unbind(slotId: slotId) }
        writeType(choice.emulatedType, key: SlotKey(connectionId: connectionId, slotId: slotId))
        let boundHere = hub.bindings[slotId] == connectionId
        if boundHere {
            setEmulatedType(slotId: slotId, type: choice.emulatedType)
        } else {
            bind(slotId: slotId, connectionId: connectionId)
        }
    }

    private func writeSwitches(_ choice: BindingChoice, slotId: String) {
        slotPreferences.setMotion(choice.motion, for: slotId)
        slotPreferences.setRumble(choice.rumble, for: slotId)
        slotPreferences.setTouchpadPick(choice.touchpad, for: slotId)
        setSlotSwitch(.mic, on: choice.mic, slotId: slotId)
        slotPreferences.setSpeaker(choice.speaker, for: slotId)
    }

    private func writeType(_ type: Int?, key: SlotKey) {
        guard let type else { return wifi.typeOverrides.clear(key) }
        wifi.typeOverrides.setType(type, for: key)
    }

    // MARK: - Following the host

    private func applyPath(_ connectionId: String) -> ApplyPath {
        guard !ConnectionHub.isMoonlight(connectionId) else { return .durable }
        let live = hub.summary(connectionId)?.live
        return sessionIsUp(live) ? .hostLive : .waitingForLink
    }

    private func follow(_ path: ApplyPath, slotId: String, connectionId: String, boundHere: Bool) {
        switch path {
        case .durable: return
        case .hostLive: resendWhereBound(connectionId, boundHere: boundHere)
        case .waitingForLink: reachForHost(connectionId)
        }
        bindingWatch.begin(sources: applySources(slotId: slotId, connectionId: connectionId), onEvent: advanceApply)
    }

    /// A pad already bound here may change nothing the descriptor carries,
    /// so the descriptor is sent again for the host to confirm; a new
    /// binding's attach sends it by itself.
    private func resendWhereBound(_ connectionId: String, boundHere: Bool) {
        guard boundHere, let conn = wifi.get(connectionId) else { return }
        Task { await wifi.syncBoundSlot(conn) }
    }

    private func reachForHost(_ connectionId: String) {
        guard hub.summary(connectionId)?.live != .connecting else { return }
        reconnect(connectionId)
    }

    private func applySources(slotId: String, connectionId: String) -> [AnyPublisher<ApplyEvent, Never>] {
        let rejected = wifi.slotRegistrationFailed
            .filter { $0 == slotId }
            .map { _ in ApplyEvent.hostRejected }
        let linkUp = hub.$connections
            .compactMap { rows in rows.first { $0.id == connectionId }?.live }
            .filter(sessionIsUp)
            .map { _ in ApplyEvent.putSent }
        let padLeft = input.$slots
            .filter { slots in !slots.contains { $0.id == slotId } }
            .map { _ in ApplyEvent.padGone }
        return [confirmations(connectionId), rejected.eraseToAnyPublisher(), linkUp.eraseToAnyPublisher(), padLeft.eraseToAnyPublisher()]
    }

    /// Every slot the satellite confirms from now on, on whichever
    /// connection object the pool holds for it.
    private func confirmations(_ connectionId: String) -> AnyPublisher<ApplyEvent, Never> {
        wifi.$connections
            .map { pool in pool[connectionId] }
            .removeDuplicates { $0 === $1 }
            .map(confirmedSlots)
            .switchToLatest()
            .eraseToAnyPublisher()
    }

    private func advanceApply(_ event: ApplyEvent) {
        let before = shellFacts.binding.progress
        let next = reduceApply(before, event)
        shellFacts.binding.progress = next
        let ended = applyInFlight(before) && !applyInFlight(next)
        if ended { bindingWatch.end() }
        let landed = next == .done && before != .done
        if landed { markDraftApplied() }
        if landed { markSetupApplied() }
    }

    private func markDraftApplied() {
        guard let draft = shellFacts.binding.draft else { return }
        shellFacts.binding.draft = reduce(draft, .applied)
    }

    /// A page that opens or leaves starts with no overlay, unless an apply still runs.
    private func settleEndedApply() {
        guard !applyInFlight(shellFacts.binding.progress) else { return }
        shellFacts.binding.progress = .idle
    }
}

@MainActor
private func confirmedSlots(_ conn: WifiConnection?) -> AnyPublisher<ApplyEvent, Never> {
    guard let conn else { return Empty().eraseToAnyPublisher() }
    return conn.$slotApplyCount
        .dropFirst()
        .map { _ in ApplyEvent.hostConfirmed }
        .eraseToAnyPublisher()
}

/// A session is up while it is live or faltering.
func sessionIsUp(_ live: LinkState?) -> Bool {
    switch live {
    case .connected, .unstable: true
    case .found, .stale, .saved, .ready, .connecting, nil: false
    }
}

extension SlotPreferences {
    init(_ choice: BindingChoice) {
        self.init(motion: choice.motion, rumble: choice.rumble, touchpad: choice.touchpad, mic: choice.mic, speaker: choice.speaker)
    }
}
