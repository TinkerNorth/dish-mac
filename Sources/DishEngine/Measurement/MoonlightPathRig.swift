// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import Foundation

/// The rig could not bring a session up on the loopback host.
package enum MoonlightPathRigError: Error, Equatable {
    case transport
    case handshake
    case padsFull
}

/// The Moonlight path wired as the manager and the composition root wire it,
/// against a host on the loopback: pads publish through their gates and feeds
/// into the host's link, the control session runs over the real UDP
/// transport with the connection's clock ticking it, and the host's events go
/// through the Moonlight feedback router to counters where a pad would be
/// actuated. The bench and the lock-law test drive the production objects
/// through it.
@MainActor
package final class MoonlightPathRig {
    /// Each pad's GameController handler queue, one per pad.
    package nonisolated let inputQueues: [DispatchQueue]
    /// Each pad's number on the host, by pad.
    package nonisolated let padNumbers: [UInt16]
    private nonisolated let gates: [PadGate]
    private nonisolated let feeds: [PadFeed]
    /// Each command the feedback router actuated, counted on the main actor.
    private nonisolated let rumbles: AtomicCounter
    private nonisolated let lights: AtomicCounter
    private let processor: GamepadInputProcessor
    private let routing: InputRouting
    private let gate: ForwardingGate
    private let connection: MoonlightConnection
    private let router: MoonlightFeedbackRouter
    private let bindings: [String: String]

    /// A session to `host` as a launch brings one up: the socket, the ENet
    /// handshake, then `pads` pads announced on it and routed to it.
    package static func connect(to host: LoopbackMoonlightHost, pads: Int) async throws -> MoonlightPathRig {
        let connection = MoonlightConnection(id: rigHostId, host: MoonlightHost(name: "Loopback", address: "127.0.0.1"))
        let transport = UdpControlTransport(address: "127.0.0.1", port: host.port)
        guard await transport.start() else { throw MoonlightPathRigError.transport }
        let session = MoonlightControlSession(
            rikey: host.rikey,
            connectData: rigConnectData,
            transport: transport,
            now: { Int64(DispatchTime.now().uptimeNanoseconds / 1_000_000) },
            onEvent: { connection.receive($0) },
            onClosed: { connection.linkClosed() }
        )
        guard await session.connect() else {
            transport.close()
            throw MoonlightPathRigError.handshake
        }
        return try MoonlightPathRig(connection: connection, session: session, pads: pads)
    }

    private init(connection: MoonlightConnection, session: MoonlightControlSession, pads: Int) throws {
        let padIds = (0 ..< pads).map { "gc:loopback-moonlight:pad\($0)" }
        let numbers = padIds.compactMap { connection.acquirePad($0, as: rigMoonlightPad)?.number }
        guard numbers.count == pads else { throw MoonlightPathRigError.padsFull }
        let processor = GamepadInputProcessor()
        let routing = InputRouting()
        let gate = ForwardingGate()
        let rumbles = AtomicCounter()
        let lights = AtomicCounter()
        self.processor = processor
        self.routing = routing
        self.gate = gate
        self.connection = connection
        self.rumbles = rumbles
        self.lights = lights
        padNumbers = numbers.map(UInt16.init)
        feeds = padIds.map { processor.feed(for: $0) }
        inputQueues = padIds.map { ThreadRole.input.queue(label: "com.tinkernorth.dish.input.\($0)", qos: .userInteractive) }
        gates = padIds.map { PadGate(key: $0, notify: ignoreGateEvent) }
        bindings = Dictionary(uniqueKeysWithValues: padIds.map { ($0, connection.id) })
        router = MoonlightFeedbackRouter(
            actuators: countingMoonlightActuators(rumbles: rumbles, lights: lights),
            gate: gate,
            table: routing.table
        )
        for padGate in gates {
            padGate.route(.standard)
        }
        connection.adopt(session: session, pinger: nil, appId: nil, appName: nil)
        router.wire([connection.id: connection])
        refreshRouting()
    }

    /// What the feedback router actuated so far.
    package var feedback: FramePathFeedback {
        FramePathFeedback(rumble: Int(rumbles.current()), lightbar: Int(lights.current()))
    }

    /// What the composition root does on every binding, pool or switch change.
    package func refreshRouting() {
        let global = ForwardingFlags()
        let flags = slotFlags(bindings: bindings, global: global, preferences: [:])
        let snapshot = routeSnapshot(bindings: bindings, pool: [:], flags: flags, global: global, moonlight: [connection.id: connection])
        routing.publish(snapshot, to: processor)
        gate.update(global)
    }

    /// The last pad leaving: the clocks stopped, TERMINATION and DISCONNECT
    /// sent, the socket closed once they have left.
    package func close() {
        connection.teardown()
    }

    /// What GameController's report handler does with a change, from the gate on.
    package nonisolated func publish(pad: Int, report: GamepadReport) {
        guard gates[pad].pass(.standard, changed: true) else { return }
        feeds[pad].publishIfChanged(report)
    }

    /// What the motion handler does with a sample.
    package nonisolated func publishMotion(pad: Int, sample: MotionSample) {
        guard gates[pad].forwards(.standard) else { return }
        feeds[pad].publishMotion(sample)
    }

    /// What the touchpad handlers do with one finger at `x`, `y`.
    package nonisolated func publishTouchpad(pad: Int, x: Int16, y: Int16) {
        guard gates[pad].forwards(.standard) else { return }
        let ids = feeds[pad].advanceTouchIds(finger0Active: true, finger1Active: false)
        let sample = TouchpadSample(
            finger0: TouchpadFinger(active: true, id: ids.finger0, x: x, y: y),
            finger1: TouchpadFinger(active: false, id: ids.finger1, x: 0, y: 0),
            buttonPressed: false
        )
        feeds[pad].publishTouchpad(sample)
    }
}

private let rigHostId = "loopback-moonlight"
private let rigConnectData: UInt32 = 0x0D15_4C0D

/// The rig's pads announce what a DualSense would, so every stream has a
/// place on the wire.
private let rigMoonlightPad = MoonlightAnnouncedPad(
    type: MoonlightControllerType.playStation,
    capabilities: 0xFF,
    supportedButtons: 0x0010_F7FF
)

/// The rig's actuators: each command the router would hand a pad, counted.
private func countingMoonlightActuators(rumbles: AtomicCounter, lights: AtomicCounter) -> MoonlightFeedbackActuators {
    MoonlightFeedbackActuators(
        rumble: { _, _, _, _ in rumbles.increment() },
        lightbar: { _, _, _, _ in lights.increment() }
    )
}
