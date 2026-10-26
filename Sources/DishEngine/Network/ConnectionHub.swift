// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Combine
import DishCore
import Foundation

/// Aggregates the satellite pool and the Moonlight hosts into the flat
/// `[ConnectionSummary]` the UI consumes, and owns the slot → connection
/// binding table and its memory across restarts. Mirrors `ConnectionHub.kt`
/// less its Bluetooth rows, which are Android's own. A satellite and a
/// Moonlight host each carry up to four pads, so binding another slot evicts
/// nothing; a fifth is refused at a satellite, and what the bindings ask of
/// each host is converged by the app.
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
    /// The satellite bindings kept across restarts; a Moonlight host's live
    /// in its manager's store.
    private let memory: BindingMemoryStore
    /// The pads whose standing binding was already tried while they stay
    /// attached, so a refused one is not retried by every emission.
    private var restoreTried: Set<String> = []
    private var cancellables = Set<AnyCancellable>()
    private var perConnCancellables: [String: AnyCancellable] = [:]
    private var perHostCancellables: [String: AnyCancellable] = [:]
    private var hosts = MoonlightRowFacts()

    init(wifi: WifiConnectionManager, store: ConnectionStore, moonlight: MoonlightConnectionManager? = nil) {
        self.wifi = wifi
        self.store = store
        self.moonlight = moonlight
        memory = store.bindingMemory

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

        // Roll back local bindings when the server rejects a controller add;
        // the memory stays, tried again when the pad next attaches.
        wifi.slotRegistrationFailed
            .sink { [weak self] slotId in self?.release(slotId: slotId) }
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
            let bound = satelliteSlotIds(id, conn: conn)
            out.append(ConnectionSummary(
                id: id,
                name: server.name,
                address: server.ip,
                udpPort: server.udpPort,
                live: live,
                boundSlotId: bound.first,
                latencyMs: conn?.latencyOneWayMs,
                compat: conn?.protocolCompat ?? .unknown,
                boundSlotIds: bound
            ))
        }
        connections = (out + moonlightSummaries()).sorted { $0.recordName < $1.recordName }
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

    /// Every slot bound to a satellite, in the order of the indices it holds there.
    private func satelliteSlotIds(_ id: String, conn: WifiConnection?) -> [String] {
        let bound = bindings.filter { $0.value == id }.keys.sorted()
        let index = { (slotId: String) in conn?.controllerIndex(of: slotId) ?? SatelliteSlots.maxPerSatellite }
        return bound.sorted { index($0) < index($1) }
    }
}

// MARK: - Binding

extension ConnectionHub {

    /// Bind `slotId` to `connectionId`; false when a satellite already
    /// carries four pads. The slot's prior owner lets go, the satellite takes
    /// the pad on the lowest free index before the table publishes (so the
    /// hot path's route already knows it), and the binding is remembered.
    /// The pad's detected capabilities become a satellite descriptor's
    /// claims, and its family picks the catalog type it is emulated as; a
    /// Moonlight pad's arrival is composed by the app.
    @discardableResult
    func bind(slotId: String, connectionId: String, capabilities: ControllerCapabilities, family: PadFamily) -> Bool {
        let toHost = Self.isMoonlight(connectionId)
        guard toHost || satelliteHasRoom(connectionId, for: slotId) else { return false }
        if let priorConnection = bindings[slotId], priorConnection != connectionId {
            releaseSlot(slotId, from: priorConnection)
        }
        if !toHost {
            let type = wifi.resolveControllerType(for: connectionId, slotId: slotId, family: family)
            wifi.get(connectionId)?.attachSlot(slotId, controllerType: type, capabilities: capabilities, family: family)
        }
        var current = bindings
        current[slotId] = connectionId
        bindings = current
        rebuild()
        if toHost { moonlight?.rememberInterest(hostId: connectionId) }
        remember(slotId: slotId, connectionId: connectionId)
        return true
    }

    /// A satellite carries four pads; a slot it already carries rebinds in place.
    private func satelliteHasRoom(_ connectionId: String, for slotId: String) -> Bool {
        let others = bindings.filter { $0.value == connectionId && $0.key != slotId }.count
        return others < SatelliteSlots.maxPerSatellite
    }

    /// The slot's connection lets go of it: a satellite detaches that pad
    /// alone, a Moonlight host's pad leaves on the next converge.
    private func releaseSlot(_ slotId: String, from connectionId: String) {
        wifi.get(connectionId)?.detachSlot(slotId)
        wifi.motionStatus.clear(SlotKey(connectionId: connectionId, slotId: slotId))
    }

    /// The user let the pad go: the binding and its memory both end.
    func unbind(slotId: String) {
        release(slotId: slotId)
        forgetMemory(slotId: slotId)
    }

    /// The pad left, or its satellite refused it: the binding ends and its
    /// memory stays, for the pad's return.
    func release(slotId: String) {
        guard let cid = bindings.removeValue(forKey: slotId) else { return }
        releaseSlot(slotId, from: cid)
        rebuild()
    }

    /// The pads attached now, from the emission itself: a binding whose pad
    /// left is released with its memory kept, and its standing binding is
    /// due again when the pad returns.
    func keepPresent(_ present: Set<String>) {
        restoreTried.formIntersection(present)
        for slotId in bindings.keys where !present.contains(slotId) {
            release(slotId: slotId)
        }
    }

    /// Forget: every pad bound to the connection lets go, and so does every
    /// binding remembered for it, whether or not its pad is here.
    func forgetBindings(of connectionId: String) {
        for (slotId, bound) in bindings where bound == connectionId {
            unbind(slotId: slotId)
        }
        memory.forgetSatellite(connectionId)
    }

    /// The user's Emulate pick for a bound slot; nil returns to the family's
    /// own type (a satellite) or the host's own pick (a Moonlight host). A
    /// live satellite binding re-sends that pad's descriptor with the new
    /// type; a Moonlight pad is re-announced by the app's converge.
    func setEmulatedType(slotId: String, type: Int?, family: PadFamily) {
        guard let connectionId = bindings[slotId] else { return }
        let key = SlotKey(connectionId: connectionId, slotId: slotId)
        if let type {
            wifi.typeOverrides.setType(type, for: key)
        } else {
            wifi.typeOverrides.clear(key)
        }
        remember(slotId: slotId, connectionId: connectionId)
        if Self.isMoonlight(connectionId) { return }
        let resolved = wifi.resolveControllerType(for: connectionId, slotId: slotId, family: family)
        wifi.get(connectionId)?.setControllerType(resolved, for: slotId)
    }

    /// The bound pad's claims changed; its descriptor follows while live.
    func setCapabilities(slotId: String, _ capabilities: ControllerCapabilities) {
        guard let connectionId = bindings[slotId] else { return }
        wifi.get(connectionId)?.setCapabilities(capabilities, for: slotId)
    }

    func boundConnection(slotId: String) -> ConnectionSummary? {
        guard let cid = bindings[slotId] else { return nil }
        return connections.first { $0.id == cid }
    }
}

// MARK: - Memory across restarts

/// A binding remembered from an earlier run, due to be bound again: the pad,
/// its destination and the type the user picked, nil for the pad's own.
struct StandingBinding: Equatable {
    let slotId: String
    let connectionId: String
    let emulatedType: Int?
}

extension ConnectionHub {

    /// One record per pad, of one kind: a satellite's in `wifi_binding_list`,
    /// a host's in `moonlight_binding_list`, so a pad that moved between the
    /// kinds is never restored to both.
    private func remember(slotId: String, connectionId: String) {
        let pick = wifi.typeOverrides.typeFor(SlotKey(connectionId: connectionId, slotId: slotId))
        if Self.isMoonlight(connectionId) {
            rememberOnHost(slotId: slotId, hostId: connectionId, pick: pick)
        } else {
            rememberOnSatellite(slotId: slotId, satelliteId: connectionId, pick: pick)
        }
    }

    private func rememberOnSatellite(slotId: String, satelliteId: String, pick: Int?) {
        memory.remember(RememberedSatelliteBinding(slotId: slotId, satelliteId: satelliteId, emulatedType: pick))
        moonlight?.forgetBinding(slotId: slotId)
    }

    /// The host's record keeps the type the pad is emulated as: the pick, else the host's own.
    private func rememberOnHost(slotId: String, hostId: String, pick: Int?) {
        memory.forget(slotId: slotId)
        guard let moonlight else { return }
        let hostType = Int(moonlight.rememberedEmulatedType(hostId: hostId))
        moonlight.rememberBinding(slotId: slotId, hostId: hostId, controllerType: pick ?? hostType)
    }

    private func forgetMemory(slotId: String) {
        memory.forget(slotId: slotId)
        moonlight?.forgetBinding(slotId: slotId)
    }

    /// The remembered bindings to bind now: each of a pad present and unbound
    /// whose destination is known here (a satellite in the pool, a host on
    /// record), each tried once while its pad stays attached. A pad that left
    /// is tried again when it returns.
    func takeDueStandingBindings(present: Set<String>, satellites: Set<String>, hosts: Set<String>) -> [StandingBinding] {
        restoreTried.formIntersection(present)
        let known = satellites.union(hosts)
        let due = standingBindings().filter { standing in
            let waiting = present.contains(standing.slotId) && bindings[standing.slotId] == nil
            return waiting && !restoreTried.contains(standing.slotId) && known.contains(standing.connectionId)
        }
        restoreTried.formUnion(due.map(\.slotId))
        return due
    }

    /// The pads remembered for a connection that it does not carry now: a
    /// Forget drops these too, so its confirmation names them.
    func standingSlotIds(of connectionId: String) -> [String] {
        standingBindings()
            .filter { $0.connectionId == connectionId && bindings[$0.slotId] != connectionId }
            .map(\.slotId)
            .sorted()
    }

    /// Every remembered binding. A Moonlight record keeps the type the pad
    /// was emulated as; it is a pick of its own only where it differs from
    /// the host's.
    private func standingBindings() -> [StandingBinding] {
        let satellites = memory.bindings().map(standingBinding)
        let hosts = (moonlight?.rememberedBindings ?? []).map(standingBinding)
        return satellites + hosts
    }

    private func standingBinding(_ record: RememberedSatelliteBinding) -> StandingBinding {
        StandingBinding(slotId: record.slotId, connectionId: record.satelliteId, emulatedType: record.emulatedType)
    }

    private func standingBinding(_ record: RememberedMoonlightBinding) -> StandingBinding {
        let hostType = moonlight.map { Int($0.rememberedEmulatedType(hostId: record.hostId)) }
        let pick = record.controllerType == hostType ? nil : record.controllerType
        return StandingBinding(slotId: record.slotId, connectionId: record.hostId, emulatedType: pick)
    }
}
