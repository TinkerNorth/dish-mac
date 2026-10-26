// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Combine
import DishCore
import Foundation

/// The setup wizard's intents: the walk is a `SetupWizardState` in the
/// shell's facts, every answer an event of its machine, and its draft is
/// the binding draft the type picker and the apply already read, so Review's
/// one write is `applyBinding`. Leaving the page drops the walk. The Local
/// Network prompt is explained before the first scan ever runs.
package extension AppModel {

    /// Open the walk, pre-answered with `slotId` when that pad is attached;
    /// a pre-answered walk opens on Destination, which looks for hosts.
    func startSetup(seed slotId: String?) {
        closeBindingDraft()
        let seed = slotId.flatMap(setupDraft)
        shellFacts.setup = SetupWizardState(seed: seed, hostKind: seed.flatMap { hostKind(of: $0) })
        adoptBindingDraft(seed)
        followSetup(padIds: input.slots.map(\.id), rows: hub.connections)
        if seed != nil { scanIfPrimed() }
    }

    func endSetup() {
        shellFacts.setup = nil
        closeBindingDraft()
        leftConnections()
    }

    func pickSetupPad(_ slotId: String) {
        guard let draft = setupDraft(slotId) else { return }
        sendSetup(.pickPad(draft, hostKind: hostKind(of: draft)))
    }

    func pickSetupDestination(_ connectionId: String) {
        let kind: SetupHostKind = ConnectionHub.isMoonlight(connectionId) ? .moonlight : .satellite
        sendSetup(.pickDestination(connectionId, kind))
    }

    func editSetup(_ event: BindingDraftEvent) {
        sendSetup(.edit(event))
    }

    func setupNext() {
        sendSetup(.next)
    }

    func setupBack() {
        sendSetup(.back)
    }

    /// A blocker's Start over: every answer goes and the walk begins again.
    func startSetupOver() {
        sendSetup(.startOver)
    }

    /// "Show me the prompt": the scan that makes macOS ask, run once the
    /// user has read why, and never explained again.
    func primeLocalNetwork() {
        markLocalNetworkPrimed()
        scanAsThePageOpens()
    }

    internal func markLocalNetworkPrimed() {
        store.onboarding.markLocalNetworkPrimed()
        shellFacts.connections.localNetworkPrimed = true
    }

    /// The page-open scan, held back until the prompt it raises has been explained.
    internal func scanIfPrimed() {
        guard shellFacts.connections.localNetworkPrimed else { return }
        scanAsThePageOpens()
    }

    /// The walk learns that its apply landed.
    internal func markSetupApplied() {
        guard shellFacts.setup != nil else { return }
        sendSetup(.applied)
    }

    internal func observeSetup() {
        shellFacts.connections.localNetworkPrimed = store.onboarding.localNetworkPrimed
        Publishers.CombineLatest(input.$slots, hub.$connections)
            .sink { [weak self] pads, rows in self?.followSetup(padIds: pads.map(\.id), rows: rows) }
            .store(in: &cancellables)
    }

    // MARK: - The machine

    internal func sendSetup(_ event: SetupWizardEvent) {
        guard let state = shellFacts.setup else { return }
        let step = reduceSetup(state, event)
        commitSetup(step.state)
        step.effects.forEach(runSetupEffect)
    }

    private func commitSetup(_ state: SetupWizardState) {
        guard state != shellFacts.setup else { return }
        let draftMoved = state.draft != shellFacts.setup?.draft
        shellFacts.setup = state
        if draftMoved { adoptBindingDraft(state.draft) }
    }

    private func runSetupEffect(_ effect: SetupWizardEffect) {
        switch effect {
        case .scan: scanIfPrimed()
        case let .apply(draft): applyBinding(draft)
        }
    }

    /// The picked pad and the chosen host, as the walk watches them. The
    /// emitted values are read, not the properties: `@Published` delivers
    /// before the write lands.
    private func followSetup(padIds: [String], rows: [ConnectionSummary]) {
        guard let draft = shellFacts.setup?.draft else { return }
        sendSetup(.padPresent(padIds.contains(draft.slotId)))
        let chosen = rows.first { $0.id == draft.current.connectionId }
        guard let chosen else { return }
        sendSetup(.hostLive(sessionIsUp(chosen.live)))
    }

    /// A draft of what the pad is bound to now; nil for a pad not attached.
    private func setupDraft(_ slotId: String) -> BindingDraft? {
        guard input.slots.contains(where: { $0.id == slotId }) else { return nil }
        return BindingDraft(slotId: slotId, original: currentChoice(slotId))
    }

    private func hostKind(of draft: BindingDraft) -> SetupHostKind? {
        draft.current.connectionId.map { ConnectionHub.isMoonlight($0) ? .moonlight : .satellite }
    }
}
