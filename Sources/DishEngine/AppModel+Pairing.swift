// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Combine
import Foundation

/// The open pairing card: its satellite and where its pairing stands.
package struct OpenPairing: Equatable {
    package let server: DiscoveredServer
    package let attempt: PairingAttempt
}

/// Pairing a satellite from its row, both paths at once as the desktops'
/// pairing sheet runs them: the operator request is filed with a fresh
/// client PIN the moment the card opens, and the typed PIN stays usable
/// beside it; whichever lands first opens the session. While the card is
/// open it is the one place its satellite's pairing failures are shown.
package extension AppModel {

    /// Each satellite's pairing as the card shows it.
    var pairingAttempts: [String: PairingAttempt] {
        wifi.pairingAttempts.state
    }

    /// The card to draw, or nil when none is open.
    var openPairing: OpenPairing? {
        guard let server = pairingTarget, let attempt = pairingAttempts[server.id] else { return nil }
        return OpenPairing(server: server, attempt: attempt)
    }

    /// Open the card on `server`'s row and file a fresh operator request.
    func beginPairing(_ server: DiscoveredServer) {
        closeCard(otherThan: server.id)
        wifi.pairWithClientPin(server, clientPin: PairingClient.generateClientPin())
        pairingTarget = server
    }

    /// A row's Pair button.
    func beginPairing(serverId: String) {
        guard let server = pairableServer(serverId) else { return }
        beginPairing(server)
    }

    /// The PIN the satellite shows, typed into the card.
    func submitPin(_ serverId: String, pin: String) {
        guard let server = pairableServer(serverId) else { return }
        wifi.pairWithPin(server, pin: pin)
    }

    /// After a decline or an expiry: the old request stops and a new code is filed.
    func newCode(_ serverId: String) {
        wifi.cancelApproval(serverId)
        beginPairing(serverId: serverId)
    }

    /// Cancel, or leaving the Connections surface: no poll outlives the card.
    func cancelPairing(_ serverId: String) {
        wifi.cancelApproval(serverId)
        if pairingTarget?.id == serverId {
            pairingTarget = nil
        }
    }

    /// The Connections surface closed with a card open.
    func leftConnections() {
        guard let open = pairingTarget else { return }
        cancelPairing(open.id)
    }

    internal func observePairing() {
        wifi.pairingAttempts.statePublisher
            .sink { [weak self] attempts in self?.followPairing(attempts) }
            .store(in: &cancellables)
    }

    /// A failure the open card shows is not told twice; one for a satellite
    /// whose card is closed is told like any other.
    internal func reportPairingFailure(serverId: String, _ failure: ConnectionFailure) {
        if pairingTarget?.id == serverId { return }
        report(failure)
    }

    /// The card redraws with every attempt, and closes when its attempt
    /// ends: a session took over, or the attempt was cancelled. The emitted
    /// value is read, not the property: `@Published` delivers before the
    /// write lands.
    private func followPairing(_ attempts: [String: PairingAttempt]) {
        objectWillChange.send()
        guard let target = pairingTarget, attempts[target.id] == nil else { return }
        pairingTarget = nil
    }

    private func closeCard(otherThan id: String) {
        guard let open = pairingTarget, open.id != id else { return }
        cancelPairing(open.id)
    }

    /// The freshest record of a satellite: the pooled connection's, then the
    /// scan's, then the remembered one.
    private func pairableServer(_ id: String) -> DiscoveredServer? {
        let pooled = wifi.get(id)?.server
        let discovered = wifi.discoveredServers.first { $0.id == id }
        let remembered = wifi.remembered().first { $0.id == id }?.toDiscovered()
        return pooled ?? discovered ?? remembered
    }
}
