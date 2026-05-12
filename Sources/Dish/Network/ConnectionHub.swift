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

    private func rebuild() {
        let pool = wifi.connections
        let remembered = Dictionary(uniqueKeysWithValues: store.remembered().map { ($0.id, $0) })
        let ids = Set(pool.keys).union(remembered.keys)
        var out: [ConnectionSummary] = []
        for id in ids {
            let conn = pool[id]
            let server = conn?.server ?? remembered[id]?.toDiscovered()
            guard let server else { continue }
            let live: ConnectionLive = switch conn?.state {
            case .connected: .connected
            case .connecting: .connecting
            default: .idle
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
    func bind(slotId: String, connectionId: String) {
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
            Task { await conn.attachSlot(slotId, controllerType: 0) }
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
