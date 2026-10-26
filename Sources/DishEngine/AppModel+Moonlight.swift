// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Combine
import DishCore
import Foundation

/// The Moonlight host that minted a PIN, as its row's card shows it.
package struct MoonlightPinPrompt: Equatable, Identifiable {
    package let host: MoonlightHost
    package let pin: String

    package init(host: MoonlightHost, pin: String) {
        self.host = host
        self.pin = pin
    }

    package var id: String {
        host.id
    }
}

/// The Moonlight half of the composition root: the bindings folded into
/// what each host is asked to carry, the hosts' feedback wired to the pads,
/// the PIN prompt, and the intents the app raises.
package extension AppModel {
    /// The feedback router follows the pool; the desire follows the
    /// bindings, the pads present, the picks, the switches and the hosts
    /// known, and converges only when it changed, so a failed session is
    /// not re-attempted by every unrelated emission.
    internal func observeMoonlight() {
        moonlight.$connections
            .sink { [weak self] pool in self?.moonlightFeedback.wire(pool) }
            .store(in: &cancellables)
        let globalSwitches = settings.objectWillChange.afterMutationSettles().map { _ in () }.prepend(())
        let picks = Publishers.CombineLatest3(wifi.typeOverrides.statePublisher, slotPreferences.statePublisher, globalSwitches)
        let hosts = Publishers.CombineLatest(moonlight.$rememberedHosts, moonlight.$connections)
        Publishers.CombineLatest4(hub.$bindings, input.$slots, picks, hosts)
            .sink { [weak self] bindings, slots, picks, hosts in
                self?.refreshDesiredPads(bindings: bindings, slots: slots, overrides: picks.0, preferences: picks.1, hosts: hosts)
            }
            .store(in: &cancellables)
        moonlight.events
            .sink { [weak self] event in self?.handleMoonlight(event) }
            .store(in: &cancellables)
    }

    private func refreshDesiredPads(
        bindings: [String: String],
        slots: [GameControllerInput.Slot],
        overrides: [SlotKey: Int],
        preferences: [String: SlotPreferences],
        hosts: (remembered: [RememberedMoonlightHost], pool: [String: MoonlightConnection])
    ) {
        let types = Dictionary(uniqueKeysWithValues: hosts.remembered.map { ($0.id, $0.emulatedType) })
        let desired = MoonlightDesire.desiredPads(
            bindings: bindings,
            hostIds: Set(hosts.remembered.map(\.id)).union(hosts.pool.keys),
            slots: slots,
            overrides: overrides,
            hostTypes: { types[$0] ?? Int(MoonlightControllerType.auto) },
            preferences: preferences,
            global: settings.flags
        )
        guard desired != lastDesired else { return }
        lastDesired = desired
        moonlight.applyDesired(desired)
    }

    /// The PIN prompt follows the pairing: shown when minted, gone once the
    /// host paired or refused. The other events are the app's to word.
    private func handleMoonlight(_ event: MoonlightConnectionEvent) {
        switch event {
        case let .pairingPinReady(host, pin):
            moonlightPin = MoonlightPinPrompt(host: host, pin: pin)
        case let .paired(host), let .pairingFailed(host, _):
            if moonlightPin?.host.id == host.id { moonlightPin = nil }
        case .hostReplaced, .appAlreadyRunning, .rejoinRefused, .launchRefused, .setupFailed, .hostFull, .endedByHost,
             .appCloseRequested, .noHostAnswered, .noAppsAvailable, .appRemoved:
            break
        }
    }

    // MARK: - Intents

    /// Pair with a host: without a PIN when it already trusts this device,
    /// else the PIN prompt follows.
    func pairMoonlight(_ hostId: String) {
        guard let host = moonlight.hostFor(hostId) else { return }
        Task { @MainActor [moonlight] in _ = await moonlight.pairHost(host) }
    }

    func cancelMoonlightPairing(_ hostId: String) {
        moonlight.cancelPairing(hostId: hostId)
        if moonlightPin?.host.id == hostId { moonlightPin = nil }
    }

    /// False for an address that is blank once trimmed; anything else is
    /// probed, and a host that does not answer is told as an event.
    @discardableResult
    func addMoonlightHost(_ text: String) -> Bool {
        guard let address = moonlightAddress(from: text) else { return false }
        moonlight.addManualHost(address)
        return true
    }

    /// Leaving the Moonlight hosts page ends the pairing its PIN card waits on.
    func leftMoonlightHosts() {
        guard let prompt = moonlightPin else { return }
        cancelMoonlightPairing(prompt.host.id)
    }

    /// Ask the host to close the app it runs; the way past a session somebody else holds.
    func quitMoonlightApp(_ hostId: String) {
        guard let host = moonlight.hostFor(hostId) else { return }
        moonlight.quitHostApp(host)
    }

    func retryMoonlightSessions() {
        moonlight.retrySessions()
    }

    /// The app a host's session starts, picked for the host: every pad on it shares the one session.
    func setMoonlightApp(_ hostId: String, appId: String, appName: String) {
        moonlight.rememberApp(hostId: hostId, appId: appId, appName: appName)
    }
}

/// A typed Moonlight address, trimmed; nil when nothing is left.
package func moonlightAddress(from text: String) -> String? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}
