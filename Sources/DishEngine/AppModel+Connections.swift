// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Combine
import DishCore
import Foundation

/// What the Connections and Moonlight hosts pages draw beyond the rows: what
/// the last scan heard and whether one runs, which satellites are pairing,
/// the Moonlight hosts' own facts, and the two questions the pages ask (a
/// Forget waiting for its answer, an address that did not read).
package struct ConnectionsFacts: Equatable {
    package var discovered: [DiscoveredServer] = []
    package var scanning = false
    package var localNetworkDenied = false
    package var pairingInFlight: Set<String> = []
    package var moonlight = MoonlightFacts()
    /// The connection whose Forget waits for the user's answer.
    package var pendingForget: String?
    /// The address field whose last entry did not read.
    package var rejectedAddress: AddressField?

    package init() {}
}

/// The Moonlight hosts' facts: the scan, the pairings in flight, each
/// session's phase, the apps a probe listed and the app picked per host.
package struct MoonlightFacts: Equatable {
    package var discovered: [MoonlightHost] = []
    package var scanning = false
    package var pairingInFlight: Set<String> = []
    package var phases: [String: MoonlightSessionPhase] = [:]
    package var apps: [String: [MoonlightApp]] = [:]
    package var pickedApps: [String: String] = [:]

    package init() {}
}

/// The two typed-address fields: a satellite's IPv4[:port], a Moonlight host's address.
package enum AddressField: Equatable {
    case satellite
    case moonlight
}

/// What a paired satellite's card offers besides Forget.
package enum SatelliteRowAction: Equatable {
    case disconnect
    case pair
    case connect
}

/// What a Moonlight host's row offers besides Forget.
package enum MoonlightRowAction: Equatable {
    case pair
    case rePair
    case disconnect
    case reconnect
    case startSession
    case retry
    case quitApp
}

/// The Connections pages' intents: the facts they draw follow the managers,
/// a row's buttons dispatch here, a Forget asks first, and a typed address
/// is read here rather than in the view.
package extension AppModel {

    internal func observeConnectionsFacts() {
        let satellites = Publishers.Merge4(
            wifi.$discoveredServers.map { _ in () },
            wifi.$isScanning.map { _ in () },
            wifi.$pairingInFlight.map { _ in () },
            wifi.$localNetworkDenied.map { _ in () }
        )
        let hosts = Publishers.Merge4(
            moonlight.$discoveredHosts.map { _ in () },
            moonlight.$isScanning.map { _ in () },
            moonlight.$pairingInFlight.map { _ in () },
            moonlight.$hostApps.map { _ in () }
        )
        let rows = Publishers.Merge(hub.$connections.map { _ in () }, moonlight.$rememberedHosts.map { _ in () })
        Publishers.Merge3(satellites, hosts, rows)
            .afterMutationSettles()
            .sink { [weak self] in self?.refreshConnectionsFacts() }
            .store(in: &cancellables)
    }

    /// Read once the managers' writes have landed, so the properties are current.
    private func refreshConnectionsFacts() {
        var facts = shellFacts.connections
        facts.discovered = wifi.discoveredServers
        facts.scanning = wifi.isScanning
        facts.localNetworkDenied = wifi.localNetworkDenied
        facts.pairingInFlight = wifi.pairingInFlight
        facts.moonlight = currentMoonlightFacts()
        guard facts != shellFacts.connections else { return }
        shellFacts.connections = facts
    }

    private func currentMoonlightFacts() -> MoonlightFacts {
        var facts = MoonlightFacts()
        facts.discovered = moonlight.discoveredHosts
        facts.scanning = moonlight.isScanning
        facts.pairingInFlight = moonlight.pairingInFlight
        facts.phases = moonlight.connections.mapValues(\.phase)
        facts.apps = moonlight.hostApps
        facts.pickedApps = Dictionary(uniqueKeysWithValues: moonlight.rememberedHosts.map { ($0.id, $0.lastAppId) })
        return facts
    }

    // MARK: - Scanning

    /// The scan a page runs as it opens: both kinds at once, and quiet about
    /// an empty or refused network, which the page's empty state says.
    func scanAsThePageOpens() {
        wifi.startDiscovery(trigger: .pageOpened)
        moonlight.startDiscovery()
    }

    /// The Moonlight hosts page's Scan: its own browse, nothing of the satellites'.
    func scanMoonlightHosts() {
        moonlight.startDiscovery()
    }

    // MARK: - A row's buttons

    func perform(_ action: SatelliteRowAction, on id: String) {
        switch action {
        case .disconnect: disconnect(id)
        case .pair: beginPairing(serverId: id)
        case .connect: reconnect(id)
        }
    }

    /// Connect a remembered satellite at its freshest known address.
    func reconnect(_ id: String) {
        guard let server = pairableServer(id) else { return }
        connect(server)
    }

    func perform(_ action: MoonlightRowAction, onHost hostId: String) {
        switch action {
        case .pair, .rePair: pairMoonlight(hostId)
        case .disconnect: disconnect(hostId)
        case .reconnect, .startSession, .retry: retryMoonlightSessions()
        case .quitApp: quitMoonlightApp(hostId)
        }
    }

    /// The app picked for a host, named by what its probe listed; the empty
    /// id is Auto, whatever the host lists first.
    func pickMoonlightApp(_ hostId: String, appId: String) {
        let listed = moonlight.hostApps[hostId] ?? []
        let title = listed.first { $0.id == appId }?.title ?? ""
        setMoonlightApp(hostId, appId: appId, appName: title)
    }

    /// The PIN card's New code: the old exchange stops and a fresh PIN is minted.
    func newMoonlightCode(_ hostId: String) {
        cancelMoonlightPairing(hostId)
        pairMoonlight(hostId)
    }

    // MARK: - Forget asks first

    func requestForget(_ id: String) {
        shellFacts.connections.pendingForget = id
    }

    func confirmForget() {
        guard let id = shellFacts.connections.pendingForget else { return }
        shellFacts.connections.pendingForget = nil
        forget(id)
    }

    func cancelForget() {
        shellFacts.connections.pendingForget = nil
    }

    // MARK: - A typed address

    /// True when the field's text read as an address and the add started;
    /// false leaves the field's error up until the next try or a dismiss.
    @discardableResult
    func addByAddress(_ field: AddressField, _ text: String) -> Bool {
        let accepted = switch field {
        case .satellite: connectManual(text)
        case .moonlight: addMoonlightHost(text)
        }
        shellFacts.connections.rejectedAddress = accepted ? nil : field
        return accepted
    }

    func clearAddressError() {
        shellFacts.connections.rejectedAddress = nil
    }
}
