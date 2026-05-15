// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import Combine
import Foundation

enum WifiState { case idle, connecting, connected }

/// A single live or potential WiFi session to one Satellite server. Owns a
/// `SatelliteClient` instance (the native UDP session) once CONNECTED.
/// Mirrors `WifiConnection.kt`.
@MainActor
final class WifiConnection: ObservableObject, Identifiable {

    let id: String
    @Published private(set) var server: DiscoveredServer
    @Published private(set) var state: WifiState = .idle
    @Published private(set) var boundSlotId: String?
    /// True while a `MSG_CONTROLLER_ADD` is awaiting `MSG_CONTROLLER_ACK`.
    /// The dashboard observes this to show a spinner.
    @Published private(set) var isRegisteringController = false

    /// Server-issued connection id, valid while CONNECTED.
    private(set) var connectionId: String?
    /// Shared reference holder for the live `SatelliteClient`. Writes happen
    /// on the main actor in `markConnected`/`markDisconnected`; reads happen
    /// on the GameController callback thread via `sendReport`. The holder is
    /// lock-protected so swapping is race-free without a main-actor hop.
    private let clientRef = ClientRef()
    var client: SatelliteClient? {
        clientRef.get()
    }

    /// Human-readable controller-registration errors (timeout or server
    /// rejection codes). Listened to by `WifiConnectionManager` and forwarded
    /// into the global event stream so the UI can surface them inline.
    let errorMessages = PassthroughSubject<String, Never>()
    /// Emitted with the slot id when registration is rejected/times out so
    /// `ConnectionHub` can roll back the local binding.
    let slotRegistrationFailed = PassthroughSubject<String, Never>()

    private var aliveTask: Task<Void, Never>?
    private var registrationTask: Task<Void, Never>?
    private var controllerAdded = false
    private var pendingControllerType = 0

    /// Set once during composition; re-applied to each fresh `SatelliteClient`
    /// in `markConnected` so we don't lose rumble across reconnects. The
    /// closure runs on the SatelliteClient's receive-loop dispatch queue.
    private var rumbleHandler: ((SatelliteClient.RumbleMessage) -> Void)?
    /// Same pattern for the decoupled `MSG_LIGHTBAR` return path.
    private var lightbarHandler: ((SatelliteClient.LightbarMessage) -> Void)?

    private nonisolated static let defaultCtrlIndex = 0
    private nonisolated static let defaultCaps: UInt16 = 0x0003
    private nonisolated static let ackWaitAttempts = 20
    private nonisolated static let ackWaitIntervalMs: UInt64 = 100

    init(id: String, server: DiscoveredServer) {
        self.id = id
        self.server = server
    }

    static func idFor(_ server: DiscoveredServer) -> String {
        server.id
    }

    func updateServer(_ server: DiscoveredServer) {
        self.server = server
    }

    func markConnecting() {
        if state == .connected { return }
        state = .connecting
    }

    /// Promote to CONNECTED. Starts the ACK receive loop + heartbeat, and if a
    /// slot was already bound it kicks the server-side controller handshake.
    func markConnected(
        client: SatelliteClient,
        connectionId: String,
        onDead: @escaping () -> Void
    ) {
        guard state == .connecting else { return }
        clientRef.set(client)
        self.connectionId = connectionId
        state = .connected
        client.resetControllerAck()
        client.rumbleHandler = rumbleHandler
        client.lightbarHandler = lightbarHandler
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
        if boundSlotId != nil, !controllerAdded {
            registrationTask = Task { [weak self] in
                guard let self else { return }
                await self.registerController(type: self.pendingControllerType)
            }
        }
    }

    func markDisconnected() {
        let existing = clientRef.get()
        if state == .idle, existing == nil { return }
        aliveTask?.cancel()
        aliveTask = nil
        registrationTask?.cancel()
        registrationTask = nil
        isRegisteringController = false
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
        registrationTask?.cancel()
        registrationTask = nil
        isRegisteringController = false
        if controllerAdded, let live = client {
            live.controllerRemove(index: Self.defaultCtrlIndex)
        }
        controllerAdded = false
    }

    private func registerController(type: Int) async {
        guard let live = clientRef.get() else { return }
        let slotId = boundSlotId
        live.resetControllerAck()
        live.controllerAdd(index: Self.defaultCtrlIndex, capabilities: Self.defaultCaps)
        isRegisteringController = true
        defer { isRegisteringController = false }

        var attempts = 0
        while attempts < Self.ackWaitAttempts, live.lastControllerAck == -1 {
            try? await Task.sleep(nanoseconds: Self.ackWaitIntervalMs * 1_000_000)
            attempts += 1
        }
        let ack = live.lastControllerAck
        if ack == -1 {
            errorMessages.send("Server did not acknowledge controller add (timeout)")
            if let slotId { slotRegistrationFailed.send(slotId) }
            return
        }
        let result = UInt8(ack & 0xFF)
        if result == 0x00 /* ACK_OK */ {
            live.sendControllerType(index: Self.defaultCtrlIndex, type: type)
            controllerAdded = true
        } else {
            errorMessages.send(Self.controllerAckErrorMessage(result))
            if let slotId { slotRegistrationFailed.send(slotId) }
        }
    }

    /// Maps the `MSG_CONTROLLER_ACK` result byte to a human-readable string.
    /// Codes match `satellite/src/core/types.h` and are kept identical to
    /// `dish-linux` and `dish-android` so users see the same text on any client.
    private nonisolated static func controllerAckErrorMessage(_ result: UInt8) -> String {
        switch result {
        case 0x01:
            "Server has no virtual gamepad backend — controller cannot be created"
        case 0x02:
            "Server has no free controller slots"
        case 0x03:
            "Controller already added on the server"
        case 0x04:
            "Controller not found on the server"
        case 0x05:
            "Server failed to plug in the virtual controller"
        default:
            "Server rejected controller add (code \(result))"
        }
    }

    // MARK: - Hot path

    /// Called directly from the GameController callback thread on every
    /// button/axis change. The `clientRef` read is a single locked pointer
    /// load (~ns on uncontended `os_unfair_lock`) and `SatelliteClient`
    /// itself serialises the `sendto` through its own lock.
    nonisolated func sendReport(
        buttons: UInt16,
        lt: UInt8,
        rt: UInt8,
        lx: Int16,
        ly: Int16,
        rx: Int16,
        ry: Int16
    ) {
        guard let live = clientRef.get() else { return }
        live.sendReport(
            controllerIndex: Self.defaultCtrlIndex,
            buttons: buttons,
            lt: lt,
            rt: rt,
            lx: lx,
            ly: ly,
            rx: rx,
            ry: ry
        )
    }

    /// Forward an IMU sample. Same threading discipline as `sendReport`:
    /// called from the GameController callback thread, must be lock-free
    /// outside of the single `sendto` inside `SatelliteClient`.
    nonisolated func sendMotion(
        gyroX: Int16, gyroY: Int16, gyroZ: Int16,
        accelX: Int16, accelY: Int16, accelZ: Int16,
        timestampDeltaUs: UInt32
    ) {
        guard let live = clientRef.get() else { return }
        live.sendMotion(
            controllerIndex: Self.defaultCtrlIndex,
            gyroX: gyroX, gyroY: gyroY, gyroZ: gyroZ,
            accelX: accelX, accelY: accelY, accelZ: accelZ,
            timestampDeltaUs: timestampDeltaUs
        )
    }

    /// Forward a battery snapshot. Sent on connect and every 30 s by the
    /// `BatteryReporter` background timer plus on charging-state transitions.
    nonisolated func sendBattery(level: UInt8, status: SatelliteClient.BatteryStatus) {
        guard let live = clientRef.get() else { return }
        live.sendBattery(
            controllerIndex: Self.defaultCtrlIndex,
            level: level,
            status: status
        )
    }

    /// Forward a touchpad sample. Same threading discipline as `sendReport` —
    /// called from a GameController touchpad callback thread.
    nonisolated func sendTouchpad(
        finger0Active: Bool, finger0X: Int16, finger0Y: Int16,
        finger1Active: Bool, finger1X: Int16, finger1Y: Int16,
        buttonPressed: Bool
    ) {
        guard let live = clientRef.get() else { return }
        // GameController doesn't surface per-finger ids; use the stable slot
        // indices 0 / 1 the way `GamepadInputProcessor.TouchpadSender` documents.
        live.sendTouchpad(
            controllerIndex: Self.defaultCtrlIndex,
            finger0Active: finger0Active, finger0Id: 0,
            finger0X: finger0X, finger0Y: finger0Y,
            finger1Active: finger1Active, finger1Id: 1,
            finger1X: finger1X, finger1Y: finger1Y,
            buttonPressed: buttonPressed
        )
    }

    /// Install (or replace) the rumble handler. Called from the AppModel
    /// during composition; we cache it on the WifiConnection so that
    /// `markConnected` can re-install it on each fresh `SatelliteClient`
    /// instance after a reconnect.
    func setRumbleHandler(_ handler: @escaping (SatelliteClient.RumbleMessage) -> Void) {
        rumbleHandler = handler
        clientRef.get()?.rumbleHandler = handler
    }

    /// Install (or replace) the light-bar handler — same cache-and-reapply
    /// pattern as `setRumbleHandler` so it survives a reconnect.
    func setLightbarHandler(_ handler: @escaping (SatelliteClient.LightbarMessage) -> Void) {
        lightbarHandler = handler
        clientRef.get()?.lightbarHandler = handler
    }
}

/// Thread-safe holder for the live `SatelliteClient` reference. Writes from
/// the main actor, reads from the GC thread — guarded by `os_unfair_lock`.
final class ClientRef: @unchecked Sendable {
    private var value: SatelliteClient?
    private var lock = os_unfair_lock_s()
    func get() -> SatelliteClient? {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return value
    }

    func set(_ newValue: SatelliteClient?) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        value = newValue
    }
}
