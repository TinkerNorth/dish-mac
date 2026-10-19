// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Combine
import DishCore
import Foundation

/// Aggregates the satellite pool and the Moonlight hosts into the flat
/// `[ConnectionSummary]` the UI consumes, and owns the slot → connection
/// binding table. Mirrors `ConnectionHub.kt` less its Bluetooth rows, which
/// are Android's own. A satellite carries one pad and evicts the prior one;
/// a Moonlight host carries up to four, so binding another slot to it evicts
/// nothing, and what the bindings ask of each host is converged by the app.
@MainActor
final class ConnectionHub: ObservableObject {

    @Published private(set) var connections: [ConnectionSummary] = []
    /// slotId -> connectionId
    @Published private(set) var bindings: [String: String] = [:]

    /// The Moonlight facts as last emitted: `@Published` delivers before the
    /// write lands, so the rows read these mirrors, never the properties.
    private struct MoonlightRowFacts {
        var pool: [String: MoonlightConnection] = [:]
        var remembered: [RememberedMoonlightHost] = []
        var discoveredIds: Set<String> = []
        var verifiedIds: Set<String> = []
    }

    private let wifi: WifiConnectionManager
    private let store: ConnectionStore
    private let moonlight: MoonlightConnectionManager?
    private var cancellables = Set<AnyCancellable>()
    private var perConnCancellables: [String: AnyCancellable] = [:]
    private var perHostCancellables: [String: AnyCancellable] = [:]
    private var hosts = MoonlightRowFacts()

    init(wifi: WifiConnectionManager, store: ConnectionStore, moonlight: MoonlightConnectionManager? = nil) {
        self.wifi = wifi
        self.store = store
        self.moonlight = moonlight

        // Rebuild summaries whenever the connection pool changes or any
        // individual connection's state changes.
        wifi.$connections
            .sink { [weak self] pool in self?.subscribeToPool(pool) }
            .store(in: &cancellables)

        // Discovery changes also flip `.ready` ⇄ `.saved` (paired-seen vs
        // paired-not-seen), so rebuild on every discovery emission. Mirrors
        // dish-android's `combine(..., satellite.discoveredServers, ...)`.
        wifi.$discoveredServers
            .sink { [weak self] _ in self?.rebuild() }
            .store(in: &cancellables)

        // The persistent "Needs pairing" set drives the `.stale` row chip;
        // mutate-on-failed-silent-retry / clear-on-live-session changes
        // happen on the manager and must trigger a summary rebuild. Mirrors
        // dish-android's `combine(..., staleSatelliteIds, ...)`.
        wifi.$staleSatelliteIds
            .afterMutationSettles()
            .sink { [weak self] _ in self?.rebuild() }
            .store(in: &cancellables)

        // Roll back local bindings when the server rejects a controller add.
        wifi.slotRegistrationFailed
            .sink { [weak self] slotId in self?.unbind(slotId: slotId) }
            .store(in: &cancellables)

        if let moonlight { observeMoonlight(moonlight) }
    }

    /// The hosts' rows follow the pool (and each connection's phase and
    /// pads), the records, the scan and the proofs of pairing.
    private func observeMoonlight(_ moonlight: MoonlightConnectionManager) {
        moonlight.$connections
            .sink { [weak self] pool in self?.subscribeToHosts(pool) }
            .store(in: &cancellables)
        moonlight.$rememberedHosts
            .sink { [weak self] remembered in
                self?.hosts.remembered = remembered
                self?.rebuild()
            }
            .store(in: &cancellables)
        moonlight.$discoveredHosts
            .sink { [weak self] discovered in
                self?.hosts.discoveredIds = Set(discovered.map(\.id))
                self?.rebuild()
            }
            .store(in: &cancellables)
        moonlight.$verifiedHostIds
            .sink { [weak self] verified in
                self?.hosts.verifiedIds = verified
                self?.rebuild()
            }
            .store(in: &cancellables)
    }

    private func subscribeToPool(_ pool: [String: WifiConnection]) {
        // Drop subscriptions for removed entries.
        for (id, _) in perConnCancellables where pool[id] == nil {
            perConnCancellables.removeValue(forKey: id)
        }
        // Add subscriptions for new entries.
        for (id, conn) in pool where perConnCancellables[id] == nil {
            let cancellable = conn.objectWillChange
                .afterMutationSettles()
                .sink { [weak self] _ in self?.rebuild() }
            perConnCancellables[id] = cancellable
        }
        // Rebuild from the EMITTED pool: `wifi.connections` is still
        // pre-mutation while `@Published` delivers (willSet), and a forget of
        // a resting row produces no later emission to self-correct on.
        rebuild(pool: pool)
    }

    private func subscribeToHosts(_ pool: [String: MoonlightConnection]) {
        for (id, _) in perHostCancellables where pool[id] == nil {
            perHostCancellables.removeValue(forKey: id)
        }
        for (id, conn) in pool where perHostCancellables[id] == nil {
            perHostCancellables[id] = conn.objectWillChange
                .afterMutationSettles()
                .sink { [weak self] _ in self?.rebuild() }
        }
        hosts.pool = pool
        rebuild()
    }

    /// Derives `LinkState` from the wire-level `SessionState`, the persistent
    /// `staleSatelliteIds` set, and whether `id` is currently in the
    /// discovery set:
    /// - `.live`      → `.connected`
    /// - `.linking`   → `.connecting`
    /// - `.faltering` → `.unstable`
    /// - `SessionState.stale` → `.unstable` while the silent re-handshake is
    ///   in flight — the row stays on the live-ish chip rather than flicking
    ///   back to `.saved` between the heartbeat drop and the retry landing.
    /// - `.idle` / no session:
    ///     id in staleSatelliteIds → `.stale` ("Needs pairing"), so the row
    ///       still tells the user that the next tap will prompt for a PIN
    ///       rather than silently retrying the same broken handshake. This
    ///       is the persistent counterpart to `SessionState.stale`'s
    ///       transient one — it survives the `disconnect`+silent-retry tear
    ///       down/rebuild cycle by living on `WifiConnectionManager` rather
    ///       than the per-connection state machine.
    ///     in discoveredIds        → `.ready`
    ///     not in discoveredIds    → `.saved`
    ///
    /// Mirrors the Android `staleSatelliteIds` derivation in
    /// `SatelliteConnectionManager.kt`.
    private func rebuild(pool: [String: WifiConnection]? = nil) {
        let pool = pool ?? wifi.connections
        let remembered = Dictionary(uniqueKeysWithValues: store.remembered().map { ($0.id, $0) })
        let discoveredIds = Set(wifi.discoveredServers.map(\.id))
        let staleIds = wifi.staleSatelliteIds
        let ids = Set(pool.keys).union(remembered.keys)
        var out: [ConnectionSummary] = []
        for id in ids {
            let conn = pool[id]
            let server = conn?.server ?? remembered[id]?.toDiscovered()
            guard let server else { continue }
            let live: LinkState = switch conn?.state {
            case .live: .connected
            case .linking: .connecting
            case .faltering, .stale: .unstable
            default: staleIds.contains(id)
                ? .stale
                : (discoveredIds.contains(id) ? .ready : .saved)
            }
            let bound = bindings.first { $0.value == id }?.key
            let label = server.name.isEmpty ? server.ip : server.name
            out.append(ConnectionSummary(
                id: id,
                label: label,
                detail: "\(server.ip) • UDP \(server.udpPort)",
                live: live,
                boundSlotId: bound,
                latencyMs: conn?.latencyOneWayMs,
                compat: conn?.protocolCompat ?? .unknown
            ))
        }
        connections = (out + moonlightSummaries()).sorted { $0.label < $1.label }
    }

    /// One row per Moonlight host in the pool or the records.
    private func moonlightSummaries() -> [ConnectionSummary] {
        let records = Dictionary(uniqueKeysWithValues: hosts.remembered.map { ($0.id, $0) })
        let ids = Set(hosts.pool.keys).union(records.keys)
        return ids.compactMap { id in
            let conn = hosts.pool[id]
            guard let host = conn?.host ?? records[id]?.host else { return nil }
            return MoonlightDesire.summary(
                host: host,
                phase: conn?.phase ?? .idle,
                roundTripMs: conn?.controlRoundTripMs,
                paired: records[id]?.paired ?? false,
                verified: hosts.verifiedIds.contains(id),
                discovered: hosts.discoveredIds.contains(id),
                boundSlotIds: bindings.filter { $0.value == id }.keys.sorted()
            )
        }
    }

    func summary(_ id: String) -> ConnectionSummary? {
        connections.first { $0.id == id }
    }

    static func isMoonlight(_ connectionId: String) -> Bool {
        connectionId.hasPrefix(MoonlightHostStore.idPrefix)
    }

    /// Bind `slotId` to `connectionId`. A satellite evicts its prior slot; a
    /// Moonlight host keeps the others it carries. The slot's prior owner on
    /// either kind lets go. The pad's detected capabilities become a
    /// satellite descriptor's claims, and its family picks the catalog type
    /// it is emulated as; a Moonlight pad's arrival is composed by the app.
    func bind(slotId: String, connectionId: String, capabilities: ControllerCapabilities, family: PadFamily) {
        var current = bindings
        let toHost = Self.isMoonlight(connectionId)
        if !toHost, let priorSlot = current.first(where: { $0.value == connectionId })?.key, priorSlot != slotId {
            current.removeValue(forKey: priorSlot)
            wifi.get(connectionId)?.detachSlot()
            wifi.motionStatus.clear(SlotKey(connectionId: connectionId, slotId: priorSlot))
        }
        if let priorConnection = current[slotId], priorConnection != connectionId {
            releaseSlot(slotId, from: priorConnection)
        }
        current[slotId] = connectionId
        bindings = current
        rebuild()
        if toHost {
            moonlight?.rememberInterest(hostId: connectionId)
            rememberMoonlightBinding(slotId: slotId, hostId: connectionId)
            return
        }
        wifi.get(connectionId)?.attachSlot(
            slotId,
            controllerType: wifi.resolveControllerType(for: connectionId, slotId: slotId, family: family),
            capabilities: capabilities,
            family: family
        )
    }

    /// The slot's connection lets go of it: a satellite detaches, a Moonlight
    /// host drops the remembered binding and its pad leaves on the next converge.
    private func releaseSlot(_ slotId: String, from connectionId: String) {
        wifi.get(connectionId)?.detachSlot()
        wifi.motionStatus.clear(SlotKey(connectionId: connectionId, slotId: slotId))
        if Self.isMoonlight(connectionId) { moonlight?.forgetBinding(slotId: slotId) }
    }

    func unbind(slotId: String) {
        guard let cid = bindings.removeValue(forKey: slotId) else { return }
        releaseSlot(slotId, from: cid)
        rebuild()
    }

    /// The user's Emulate pick for a bound slot; nil returns to the family's
    /// own type (a satellite) or the host's own pick (a Moonlight host). A
    /// live satellite binding re-sends its descriptor with the new type; a
    /// Moonlight pad is re-announced by the app's converge.
    func setEmulatedType(slotId: String, type: Int?, family: PadFamily) {
        guard let connectionId = bindings[slotId] else { return }
        let key = SlotKey(connectionId: connectionId, slotId: slotId)
        if let type {
            wifi.typeOverrides.setType(type, for: key)
        } else {
            wifi.typeOverrides.clear(key)
        }
        if Self.isMoonlight(connectionId) {
            rememberMoonlightBinding(slotId: slotId, hostId: connectionId)
            return
        }
        wifi.get(connectionId)?.setControllerType(wifi.resolveControllerType(for: connectionId, slotId: slotId, family: family))
    }

    /// The binding as kept across restarts: the pick for this pad, else the host's own.
    private func rememberMoonlightBinding(slotId: String, hostId: String) {
        guard let moonlight else { return }
        let pick = wifi.typeOverrides.typeFor(SlotKey(connectionId: hostId, slotId: slotId))
        moonlight.rememberBinding(
            slotId: slotId,
            hostId: hostId,
            controllerType: pick ?? Int(moonlight.rememberedEmulatedType(hostId: hostId))
        )
    }

    /// The bound pad's claims changed; the descriptor follows while live.
    func setCapabilities(slotId: String, _ capabilities: ControllerCapabilities) {
        guard let connectionId = bindings[slotId] else { return }
        wifi.get(connectionId)?.setCapabilities(capabilities)
    }

    func boundConnection(slotId: String) -> ConnectionSummary? {
        guard let cid = bindings[slotId] else { return nil }
        return connections.first { $0.id == cid }
    }
}
