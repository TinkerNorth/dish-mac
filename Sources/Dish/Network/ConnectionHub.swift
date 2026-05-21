// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Combine
import Foundation

/// Aggregates the wifi connection pool into the flat `[ConnectionSummary]`
/// the UI consumes, and owns the slot→connection binding table. Mirrors the
/// WiFi-only subset of `ConnectionHub.kt` — the Mac client doesn't speak the
/// Android Bluetooth-HID-Device protocol (that's Android-specific) so BT is
/// omitted.
@MainActor
final class ConnectionHub: ObservableObject {

    @Published private(set) var connections: [ConnectionSummary] = []
    /// slotId -> connectionId
    @Published private(set) var bindings: [String: String] = [:]

    private let wifi: WifiConnectionManager
    private let store: ConnectionStore
    private var cancellables = Set<AnyCancellable>()
    private var perConnCancellables: [String: AnyCancellable] = [:]

    init(wifi: WifiConnectionManager, store: ConnectionStore) {
        self.wifi = wifi
        self.store = store

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

        // Roll back local bindings when the server rejects a controller add.
        wifi.slotRegistrationFailed
            .sink { [weak self] slotId in self?.unbind(slotId: slotId) }
            .store(in: &cancellables)
    }

    private func subscribeToPool(_ pool: [String: WifiConnection]) {
        // Drop subscriptions for removed entries.
        for (id, _) in perConnCancellables where pool[id] == nil {
            perConnCancellables.removeValue(forKey: id)
        }
        // Add subscriptions for new entries.
        for (id, conn) in pool where perConnCancellables[id] == nil {
            let cancellable = conn.objectWillChange.sink { [weak self] _ in
                // objectWillChange fires *before* the mutation; defer one tick.
                DispatchQueue.main.async { self?.rebuild() }
            }
            perConnCancellables[id] = cancellable
        }
        rebuild()
    }

    /// Derives `LinkState` from the wire-level `SessionState` plus whether
    /// `id` is currently in the discovery set:
    /// - `.live`      → `.connected`
    /// - `.linking`   → `.connecting`
    /// - `.faltering` → `.unstable` (not yet reachable; native exposes only
    ///   the binary alive-poll boolean)
    /// - `.stale`     → `.unstable` while the silent re-handshake is in
    ///   flight — the row stays on the live-ish chip rather than flicking
    ///   back to `.saved` between the heartbeat drop and the retry landing.
    /// - `.idle` / no session:
    ///     in discoveredIds     → `.ready`
    ///     not in discoveredIds → `.saved`
    ///
    /// TODO(stale-marker): a server-side forget should also surface
    /// `.stale` on the row chip ("Needs pairing") after a silent
    /// auto-reconnect comes back with `authRequired`. That requires
    /// tracking a per-server "stale" marker alongside the SessionState (the
    /// Android equivalent is `staleSatelliteIds`); for now a forgotten
    /// device falls back to `.saved`/`.ready` and only the next
    /// user-initiated tap surfaces the PIN prompt.
    private func rebuild() {
        let pool = wifi.connections
        let remembered = Dictionary(uniqueKeysWithValues: store.remembered().map { ($0.id, $0) })
        let discoveredIds = Set(wifi.discoveredServers.map(\.id))
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
            default: discoveredIds.contains(id) ? .ready : .saved
            }
            let bound = bindings.first { $0.value == id }?.key
            let label = server.name.isEmpty ? server.ip : server.name
            out.append(ConnectionSummary(
                id: id,
                label: label,
                detail: "\(server.ip) • UDP \(server.udpPort)",
                live: live,
                boundSlotId: bound
            ))
        }
        connections = out.sorted { $0.label < $1.label }
    }

    func summary(_ id: String) -> ConnectionSummary? {
        connections.first { $0.id == id }
    }

    /// Bind `slotId` to `connectionId`. Evicts any prior owner on either side.
    ///
    /// `hasMotion` / `hasLight` report whether the bound physical controller
    /// exposes a `GCMotion` IMU / an addressable RGB light; they are forwarded
    /// into the `MSG_CONTROLLER_ADD` capability word as `CAP_MOTION` /
    /// `CAP_LIGHTBAR`. The caller (`AppModel`) resolves them from the slot's
    /// detected `ControllerCapabilities` — `ConnectionHub` has no controller
    /// handle of its own.
    func bind(slotId: String, connectionId: String, hasMotion: Bool, hasLight: Bool) {
        var current = bindings
        if let priorSlot = current.first(where: { $0.value == connectionId })?.key,
           priorSlot != slotId
        {
            current.removeValue(forKey: priorSlot)
            wifi.get(connectionId)?.detachSlot()
        }
        current[slotId] = connectionId
        bindings = current
        rebuild()
        if let conn = wifi.get(connectionId) {
            Task {
                await conn.attachSlot(
                    slotId,
                    controllerType: 0,
                    hasMotion: hasMotion,
                    hasLight: hasLight
                )
            }
        }
    }

    func unbind(slotId: String) {
        guard let cid = bindings.removeValue(forKey: slotId) else { return }
        wifi.get(cid)?.detachSlot()
        rebuild()
    }

    func boundConnection(slotId: String) -> ConnectionSummary? {
        guard let cid = bindings[slotId] else { return nil }
        return connections.first { $0.id == cid }
    }
}
