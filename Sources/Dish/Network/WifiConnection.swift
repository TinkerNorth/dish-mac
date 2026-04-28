// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Foundation
import Combine

enum WifiState { case idle, connecting, connected }

/// A single live or potential WiFi session to one Satellite server. Owns a
/// `SatelliteClient` instance (the native UDP session) once CONNECTED.
/// Mirrors `WifiConnection.kt`.
@MainActor
final class WifiConnection: ObservableObject, Identifiable {

    let id: String
    @Published private(set) var server: DiscoveredServer
    @Published private(set) var state: WifiState = .idle
    @Published private(set) var boundSlotId: String? = nil

    /// Server-issued connection id, valid while CONNECTED.
    private(set) var connectionId: String? = nil
    /// Shared reference holder for the live `SatelliteClient`. Writes happen
    /// on the main actor in `markConnected`/`markDisconnected`; reads happen
    /// on the GameController callback thread via `sendReport`. The holder is
    /// lock-protected so swapping is race-free without a main-actor hop.
    private let clientRef = ClientRef()
    var client: SatelliteClient? { clientRef.get() }

    private var aliveTask: Task<Void, Never>? = nil
    private var controllerAdded = false
    private var pendingControllerType: Int = 0

    private static let defaultCtrlIndex = 0
    private static let defaultCaps: UInt16 = 0x0003
    private static let ackWaitAttempts = 20
    private static let ackWaitIntervalMs: UInt64 = 100

    init(id: String, server: DiscoveredServer) {
        self.id = id
        self.server = server
    }

    static func idFor(_ server: DiscoveredServer) -> String { server.id }

    func updateServer(_ server: DiscoveredServer) { self.server = server }

    func markConnecting() {
        if state == .connected { return }
        state = .connecting
    }

    /// Promote to CONNECTED. Starts the ACK receive loop + heartbeat, and if a
    /// slot was already bound it kicks the server-side controller handshake.
    func markConnected(client: SatelliteClient, connectionId: String,
                       onDead: @escaping () -> Void) {
        guard state == .connecting else { return }
        clientRef.set(client)
        self.connectionId = connectionId
        state = .connected
        client.resetControllerAck()
        client.startReceiveLoop()
        client.startHeartbeat()

        aliveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self else { return }
                if self.clientRef.get()?.connectionAlive == false {
                    await MainActor.run { onDead() }
                    return
                }
            }
        }
        if boundSlotId != nil && !controllerAdded {
            Task { await self.registerController(type: pendingControllerType) }
        }
    }

    func markDisconnected() {
        let existing = clientRef.get()
        if state == .idle && existing == nil { return }
        aliveTask?.cancel(); aliveTask = nil
        existing?.stopHeartbeat()
        existing?.closeSocket()
        clientRef.set(nil)
        connectionId = nil
        controllerAdded = false
        state = .idle
    }

    // MARK: - Slot binding

    func attachSlot(_ slotId: String, controllerType: Int) async {
        boundSlotId = slotId
        pendingControllerType = controllerType
        if state == .connected, !controllerAdded {
            await registerController(type: controllerType)
        }
    }

    func detachSlot() {
        if boundSlotId == nil { return }
        boundSlotId = nil
        if controllerAdded, let c = client {
            c.controllerRemove(index: Self.defaultCtrlIndex)
        }
        controllerAdded = false
    }

    private func registerController(type: Int) async {
        guard let c = clientRef.get() else { return }
        c.resetControllerAck()
        c.controllerAdd(index: Self.defaultCtrlIndex, capabilities: Self.defaultCaps)
        var attempts = 0
        while attempts < Self.ackWaitAttempts && c.lastControllerAck == -1 {
            try? await Task.sleep(nanoseconds: Self.ackWaitIntervalMs * 1_000_000)
            attempts += 1
        }
        if c.lastControllerAck != -1 {
            c.sendControllerType(index: Self.defaultCtrlIndex, type: type)
            controllerAdded = true
        }
    }

    // MARK: - Hot path

    /// Called directly from the GameController callback thread on every
    /// button/axis change. The `clientRef` read is a single locked pointer
    /// load (~ns on uncontended `os_unfair_lock`) and `SatelliteClient`
    /// itself serialises the `sendto` through its own lock.
    nonisolated func sendReport(buttons: UInt16, lt: UInt8, rt: UInt8,
                                lx: Int16, ly: Int16, rx: Int16, ry: Int16) {
        guard let c = clientRef.get() else { return }
        c.sendReport(controllerIndex: Self.defaultCtrlIndex,
                     buttons: buttons, lt: lt, rt: rt,
                     lx: lx, ly: ly, rx: rx, ry: ry)
    }
}

/// Thread-safe holder for the live `SatelliteClient` reference. Writes from
/// the main actor, reads from the GC thread — guarded by `os_unfair_lock`.
final class ClientRef: @unchecked Sendable {
    private var value: SatelliteClient?
    private var lock = os_unfair_lock_s()
    func get() -> SatelliteClient? {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        return value
    }
    func set(_ v: SatelliteClient?) {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        value = v
    }
}
