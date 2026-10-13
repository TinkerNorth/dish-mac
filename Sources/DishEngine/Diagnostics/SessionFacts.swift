// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// A satellite session as the Diagnostics window reads it, taken off the
// connection and its client together on the main actor: the negotiation,
// the ack-fed epoch and bitmap against what this client applied, the
// backend, the heartbeats, the grant and the round trips; and the bound
// slot's side of the wire. Data only; the window words it.

import DishCore
import Foundation

package struct HostSessionFacts: Equatable {
    package let id: String
    package let live: Bool
    package let offeredProtocol: Int
    package let settledProtocol: Int
    package let compat: ProtocolCompat
    /// -1 while no session.
    package let appliedEpoch: Int
    /// The ack-fed fields read nil until the first enriched ack.
    package let hostEpoch: Int?
    package let hostBitmap: UInt16?
    package let confirmedBitmap: UInt16
    package let backendAvailable: Bool?
    package let activeControllers: Int?
    package let missedAcks: Int
    package let mouseControlGranted: Bool
    package let latency: LatencySummary
    /// What the probe granted of the pad's own audio; `.none` until it lands.
    package let audio: HostAudioVerdict

    package init(
        id: String, live: Bool, offeredProtocol: Int, settledProtocol: Int, compat: ProtocolCompat, appliedEpoch: Int,
        hostEpoch: Int?, hostBitmap: UInt16?, confirmedBitmap: UInt16, backendAvailable: Bool?, activeControllers: Int?,
        missedAcks: Int, mouseControlGranted: Bool, latency: LatencySummary, audio: HostAudioVerdict = .none
    ) {
        self.id = id
        self.live = live
        self.offeredProtocol = offeredProtocol
        self.settledProtocol = settledProtocol
        self.compat = compat
        self.appliedEpoch = appliedEpoch
        self.hostEpoch = hostEpoch
        self.hostBitmap = hostBitmap
        self.confirmedBitmap = confirmedBitmap
        self.backendAvailable = backendAvailable
        self.activeControllers = activeControllers
        self.missedAcks = missedAcks
        self.mouseControlGranted = mouseControlGranted
        self.latency = latency
        self.audio = audio
    }

    /// A remembered satellite with no connection in the pool.
    package static func resting(id: String) -> HostSessionFacts {
        HostSessionFacts(
            id: id,
            live: false,
            offeredProtocol: ProtocolConstants.protocolVersion,
            settledProtocol: ProtocolConstants.protocolVersionMin,
            compat: .unknown,
            appliedEpoch: -1,
            hostEpoch: nil,
            hostBitmap: nil,
            confirmedBitmap: 0,
            backendAvailable: nil,
            activeControllers: nil,
            missedAcks: 0,
            mouseControlGranted: false,
            latency: LatencySummary(p50RttMs: nil, p99RttMs: nil, samples: 0, capacity: LatencyWindow.capacity)
        )
    }
}

@MainActor
package func hostSessionFacts(of conn: WifiConnection) -> HostSessionFacts {
    let ack = conn.lastHeartbeatAck
    let confirmed: UInt16 = conn.slotApplied ? UInt16(1) << UInt16(WifiConnection.defaultCtrlIndex) : 0
    return HostSessionFacts(
        id: conn.id,
        live: conn.hasLiveSession,
        offeredProtocol: conn.offeredProtocolVersion,
        settledProtocol: conn.settledProtocolVersion,
        compat: conn.protocolCompat,
        appliedEpoch: conn.lastAppliedEpoch,
        hostEpoch: ack.map { Int($0.epoch) },
        hostBitmap: ack?.bitmap,
        confirmedBitmap: confirmed,
        backendAvailable: ack?.backendAvailable,
        activeControllers: ack.map { Int($0.activeCount) },
        missedAcks: conn.client?.missedAcks.get() ?? 0,
        mouseControlGranted: conn.mouseControlGranted,
        latency: conn.client?.latencySummary() ?? HostSessionFacts.resting(id: conn.id).latency,
        audio: conn.hostAudio
    )
}

/// How the touchpad rides the wire, as the descriptor declares it.
package enum WireTouchpad: Equatable {
    case off
    case pad
    case mouse
}

/// A binding's side of the wire on its satellite: the index it holds there,
/// what its descriptor declared, and whether the host confirmed it and
/// reports it streaming.
package struct SlotWireFacts: Equatable {
    package let controllerIndex: Int
    package let type: Int
    package let caps: UInt16
    package let touchpad: WireTouchpad
    package let confirmed: Bool
    package let streaming: Streaming

    package init(controllerIndex: Int, type: Int, caps: UInt16, touchpad: WireTouchpad, confirmed: Bool, streaming: Streaming) {
        self.controllerIndex = controllerIndex
        self.type = type
        self.caps = caps
        self.touchpad = touchpad
        self.confirmed = confirmed
        self.streaming = streaming
    }
}

/// Nil for a connection that carries no descriptor.
@MainActor
package func slotWireFacts(of conn: WifiConnection) -> SlotWireFacts? {
    guard let descriptor = conn.desiredDescriptor else { return nil }
    return SlotWireFacts(
        controllerIndex: descriptor.ctrlIdx,
        type: Int(descriptor.type),
        caps: descriptor.caps,
        touchpad: wireTouchpad(descriptor.touchpadMode),
        confirmed: conn.slotApplied,
        streaming: streamingOf(hostBitmap: conn.lastHeartbeatAck?.bitmap, controllerIndex: descriptor.ctrlIdx)
    )
}

func wireTouchpad(_ mode: TouchpadMode) -> WireTouchpad {
    switch mode {
    case .off: .off
    case .ds4: .pad
    case .mouse: .mouse
    }
}
