// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import DishCore
import Foundation

/// The RTSP client as the session runs it, one step per reducer effect.
protocol MoonlightRtspStepping: AnyObject {
    func perform(_ step: MoonlightRtspStep, config: MoonlightStreamConfig) async -> Bool
    var negotiated: MoonlightStreamPorts? { get }
}

extension MoonlightRtspClient: MoonlightRtspStepping {}

/// The sockets under a session, behind one seam so the lifecycle is tested
/// without a host: the RTSP handshake, the media pings and the control link.
protocol MoonlightSessionEdges: AnyObject {
    func rtspClient(address: String, port: UInt16) -> MoonlightRtspStepping
    func mediaPinger(address: String, ports: MoonlightStreamPorts) -> MoonlightMediaPinger
    func connectControl(
        address: String,
        ports: MoonlightStreamPorts,
        rikey: Data,
        onEvent: @escaping (MoonlightEvent) -> Void,
        onClosed: @escaping () -> Void
    ) async -> MoonlightLiveSession?
}

/// The real sockets.
final class LiveMoonlightSessionEdges: MoonlightSessionEdges {
    func rtspClient(address: String, port: UInt16) -> MoonlightRtspStepping {
        MoonlightRtspClient(address: address, port: port)
    }

    func mediaPinger(address: String, ports: MoonlightStreamPorts) -> MoonlightMediaPinger {
        MoonlightMediaPinger(address: address, videoPort: ports.videoPort, audioPort: ports.audioPort, payload: ports.pingPayload)
    }

    /// The UDP socket to the control port, then the ENet handshake over it;
    /// nil when either fails, with the socket closed again.
    func connectControl(
        address: String,
        ports: MoonlightStreamPorts,
        rikey: Data,
        onEvent: @escaping (MoonlightEvent) -> Void,
        onClosed: @escaping () -> Void
    ) async -> MoonlightLiveSession? {
        let transport = UdpControlTransport(address: address, port: ports.controlPort)
        guard await transport.start() else { return nil }
        let session = MoonlightControlSession(
            rikey: rikey,
            connectData: ports.connectData,
            transport: transport,
            now: { Int64(DispatchTime.now().uptimeNanoseconds / 1_000_000) },
            onEvent: onEvent,
            onClosed: onClosed
        )
        guard await session.connect() else {
            transport.close()
            return nil
        }
        return session
    }
}
