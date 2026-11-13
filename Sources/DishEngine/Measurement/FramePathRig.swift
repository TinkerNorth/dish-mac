// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import CryptoKit
import DishCore
import Foundation
import IOKit.hid

/// The rig could not reach the loopback satellite or route a pad.
package enum FramePathRigError: Error, Equatable {
    case socket
    case slotsFull
    case directPad
}

/// The frame and receive paths wired as the composition root wires them,
/// against a satellite on the loopback: pads publish through their gates,
/// the input processor, the routing table and a live connection's client,
/// whose receive loop, heartbeat and alive tick run as they do in the app.
/// The return paths are counted where a controller would be actuated. The
/// bench and the lock-law test drive the production objects through it.
@MainActor
package final class FramePathRig {
    /// Each pad's GameController handler queue, one per pad as the bridge
    /// makes one per controller.
    package nonisolated let inputQueues: [DispatchQueue]
    /// Each pad's index on the satellite, by pad number.
    package nonisolated let controllerIndices: [Int]
    private nonisolated let padIds: [String]
    private nonisolated let gates: [PadGate]
    private nonisolated let processor: GamepadInputProcessor
    /// Each pad's feed, as GameController's handlers hold theirs.
    private nonisolated let feeds: [PadFeed]
    private nonisolated let connection: WifiConnection
    private let client = SatelliteClient()
    private let routing: InputRouting
    private let router: ReturnPathRouter
    /// Each command the feedback queue applied, counted on that queue.
    private nonisolated let rumbles: AtomicCounter
    private nonisolated let lightbars: AtomicCounter
    private var bindings: [String: String]
    private var lanes: [HidPadLane] = []

    package init(satellitePort: UInt16, token: UInt32, key: SymmetricKey, pads: Int) throws {
        let server = DiscoveredServer(name: "Loopback", ip: "127.0.0.1", udpPort: Int(satellitePort), machineId: "loopback-satellite")
        let connection = WifiConnection(id: server.id, server: server)
        let padIds = (0 ..< pads).map { "gc:loopback:pad\($0)" }
        let indices = padIds.compactMap { connection.attachSlot($0, controllerType: 0, capabilities: rigCapabilities) }
        guard indices.count == pads else { throw FramePathRigError.slotsFull }
        let routing = InputRouting()
        let processor = GamepadInputProcessor()
        self.processor = processor
        feeds = padIds.map { processor.feed(for: $0) }
        inputQueues = padIds.map { ThreadRole.input.queue(label: "com.tinkernorth.dish.input.\($0)", qos: .userInteractive) }
        self.connection = connection
        self.padIds = padIds
        self.routing = routing
        controllerIndices = indices
        gates = padIds.map { PadGate(key: $0, notify: ignoreGateEvent) }
        bindings = Dictionary(uniqueKeysWithValues: padIds.map { ($0, connection.id) })
        let rumbles = AtomicCounter()
        let lightbars = AtomicCounter()
        self.rumbles = rumbles
        self.lightbars = lightbars
        router = ReturnPathRouter(feedback: PadFeedback(actuators: countingActuators(rumbles: rumbles, lightbars: lightbars)))
        try connect(port: satellitePort, token: token, key: key)
    }

    /// What the return paths asked of the controllers so far.
    package var feedback: FramePathFeedback {
        FramePathFeedback(rumble: Int(rumbles.current()), lightbar: Int(lightbars.current()))
    }

    /// The reports the tally counted, as the telemetry tick reads it.
    package func reportsCounted() -> UInt64 {
        processor.tallySnapshot().reports.values.reduce(0, +)
    }

    /// What the composition root does on every binding, pool or switch change.
    package func refreshRouting() {
        let global = ForwardingFlags()
        let pool = [connection.id: connection]
        let flags = slotFlags(bindings: bindings, global: global, preferences: [:])
        let snapshot = routeSnapshot(bindings: bindings, pool: pool, flags: flags, global: global)
        routing.publish(snapshot, to: processor)
        router.route(snapshot, global: global)
        connection.setForwardingFlags(global)
        connection.setSlotFlags(flags)
    }

    package func stopHeartbeat() {
        client.stopHeartbeat()
    }

    package func close() {
        connection.markDisconnected()
    }

    /// A Switch Pro pad read directly, on the next free index and routed like
    /// any slot; its reports go through IOKit's callback.
    package func addSwitchProLane() throws -> DirectFeed {
        let attached = try attachDirectLane(switchProProperties(), productKey: "057e:2009")
        return DirectFeed(lane: attached.lane, controllerIndex: attached.index)
    }

    /// A 2015 Steam Controller read directly with its trackpads picked as
    /// the touch surface, so each report lands on the input frame and the
    /// touchpad frame both.
    package func addSteamControllerLane() throws -> SteamPadFeed {
        let attached = try attachDirectLane(steamControllerProperties(), productKey: "28de:1102")
        attached.lane.useTrackpadPick(.pad)
        return SteamPadFeed(lane: attached.lane, controllerIndex: attached.index)
    }

    private func attachDirectLane(_ properties: [String: Any], productKey: String) throws -> (lane: HidPadLane, index: Int) {
        guard let candidate = hidPadCandidate(properties) else { throw FramePathRigError.directPad }
        let slotId = HidPadLimits.slotIdPrefix + productKey
        guard let index = connection.attachSlot(slotId, controllerType: 0, capabilities: rigCapabilities) else {
            throw FramePathRigError.slotsFull
        }
        let wiring = HidPadWiring(processor: processor, notify: ignoreGateEvent, battery: ignoreBattery)
        let lane = HidPadLane(slotId: slotId, candidate: candidate, wiring: wiring, openedNs: DispatchTime.now().uptimeNanoseconds)
        lane.gate.route(.direct)
        lanes.append(lane)
        bindings[slotId] = connection.id
        refreshRouting()
        return (lane, index)
    }

    /// What GameController's report handler does with a change, from the
    /// gate on; GameController's own sampling of the pad is not part of it.
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

    /// One encoded microphone packet, as the capture queue hands it over.
    package nonisolated func sendMic(pad: Int, opus: Data) {
        connection.sendMicAudio(opus: opus, controllerIndex: controllerIndices[pad])
    }

    private func connect(port: UInt16, token: UInt32, key: SymmetricKey) throws {
        for gate in gates {
            gate.route(.standard)
        }
        let aimed = client.setConnectionParams(
            host: "127.0.0.1",
            udpPort: port,
            token: token,
            sessionKey: key,
            protocolVersion: ProtocolConstants.protocolVersion
        )
        guard aimed else { throw FramePathRigError.socket }
        connection.markConnecting()
        connection.markConnected(client: client, connectionId: "loopback", epoch: 0, hooks: SessionHooks())
        router.wire([connection.id: connection])
        refreshRouting()
    }
}

/// What the return paths asked of the controllers.
package struct FramePathFeedback: Equatable {
    package var rumble = 0
    package var lightbar = 0
}

/// One Direct pad's reports, written into the lane's buffer and handed to
/// IOKit's callback the way the reader's run loop hands them.
package final class DirectFeed: @unchecked Sendable {
    private static let reportLength = 64
    private static let rightStick = 9
    /// A full 0x30 report at rest: battery, buttons, left stick centred
    /// (2048, 2048 packed), and three empty IMU frames.
    private static let restingReport: [UInt8] = [0x30, 0x00, 0x91, 0x00, 0x00, 0x00, 0x00, 0x08, 0x80]

    package let controllerIndex: Int
    private let lane: HidPadLane

    init(lane: HidPadLane, controllerIndex: Int) {
        self.lane = lane
        self.controllerIndex = controllerIndex
        lane.buffer.update(repeating: 0, count: lane.capacity)
        for (offset, byte) in Self.restingReport.enumerated() {
            lane.buffer[offset] = byte
        }
    }

    /// One full report whose right stick reads the raw 12-bit `x` and `y`.
    package func feed(rightStickX x: UInt16, rightStickY y: UInt16) {
        lane.buffer[Self.rightStick] = UInt8(truncatingIfNeeded: x)
        lane.buffer[Self.rightStick + 1] = UInt8(truncatingIfNeeded: x >> 8) & 0x0F | UInt8(truncatingIfNeeded: y << 4)
        lane.buffer[Self.rightStick + 2] = UInt8(truncatingIfNeeded: y >> 4)
        hidPadReportCallback(
            context: Unmanaged.passUnretained(lane).toOpaque(),
            result: kIOReturnSuccess,
            sender: nil,
            type: kIOHIDReportTypeInput,
            reportId: 0,
            report: lane.buffer,
            length: min(Self.reportLength, lane.capacity)
        )
    }
}

/// A 2015 Steam Controller's state packets with a finger on the right
/// trackpad, written into the lane's buffer and handed to IOKit's callback.
package final class SteamPadFeed: @unchecked Sendable {
    private static let reportLength = 64
    private static let rightPad = 20
    /// A state packet (type 1, 44 bytes) at rest but for the right pad's
    /// finger bit.
    private static let fingerOnRightPad: [UInt8] = [0x01, 0x00, 0x01, 0x2C, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10]

    package let controllerIndex: Int
    private let lane: HidPadLane

    init(lane: HidPadLane, controllerIndex: Int) {
        self.lane = lane
        self.controllerIndex = controllerIndex
        lane.buffer.update(repeating: 0, count: lane.capacity)
        for (offset, byte) in Self.fingerOnRightPad.enumerated() {
            lane.buffer[offset] = byte
        }
    }

    /// One state packet whose right pad reads `x`, `y` before the shell rotation.
    package func feed(rightPadX x: Int16, rightPadY y: Int16) {
        lane.buffer[Self.rightPad] = UInt8(truncatingIfNeeded: x)
        lane.buffer[Self.rightPad + 1] = UInt8(truncatingIfNeeded: x >> 8)
        lane.buffer[Self.rightPad + 2] = UInt8(truncatingIfNeeded: y)
        lane.buffer[Self.rightPad + 3] = UInt8(truncatingIfNeeded: y >> 8)
        hidPadReportCallback(
            context: Unmanaged.passUnretained(lane).toOpaque(),
            result: kIOReturnSuccess,
            sender: nil,
            type: kIOHIDReportTypeInput,
            reportId: 0,
            report: lane.buffer,
            length: min(Self.reportLength, lane.capacity)
        )
    }
}

/// The rig's pads declare what a DualSense would, so every stream routes.
private let rigCapabilities = ControllerCapabilities(
    hasMotion: true,
    hasTouchpad: true,
    hasRumble: true,
    hasLightbar: true,
    hasBattery: true,
    hasTriggerEffects: false,
    hasPlayerLeds: false
)

private func switchProProperties() -> [String: Any] {
    [
        kIOHIDVendorIDKey: 0x057E, kIOHIDProductIDKey: 0x2009, kIOHIDProductKey: "Pro Controller",
        kIOHIDTransportKey: kIOHIDTransportUSBValue, kIOHIDMaxInputReportSizeKey: 64
    ]
}

/// The wired 2015 pad's vendor interface, the one its state packets ride.
private func steamControllerProperties() -> [String: Any] {
    [
        kIOHIDVendorIDKey: 0x28DE, kIOHIDProductIDKey: 0x1102, kIOHIDProductKey: "Steam Controller",
        kIOHIDTransportKey: kIOHIDTransportUSBValue, kIOHIDPrimaryUsagePageKey: 0xFF00, kIOHIDPrimaryUsageKey: 0x0001,
        kIOHIDMaxInputReportSizeKey: 64, hidInterfaceNumberKey: 2
    ]
}

/// A rig's gates tell nobody about a pad's source moving.
@Sendable
func ignoreGateEvent(_: String, _: InputSource) {}

@Sendable
private func ignoreBattery(_: String, _: PadBattery) {}

/// The rig's actuators: each command the feedback queue would apply, counted.
private func countingActuators(rumbles: AtomicCounter, lightbars: AtomicCounter) -> FeedbackActuators {
    FeedbackActuators(
        rumble: { _, _, _, _ in rumbles.increment() },
        lightbar: { _, _, _, _ in lightbars.increment() },
        triggerEffects: { _, _ in },
        playerLeds: { _, _ in }
    )
}
