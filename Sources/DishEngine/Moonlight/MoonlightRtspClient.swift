// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// The plaintext RTSP handshake over TCP, one connection per message because
// a Moonlight host answers exactly one message per connection and hangs up:
// an idle read straight after the OPTIONS reply returns end of stream, and a
// second message written into that socket is never seen at all. The reply
// is framed by that hang-up as much as by Content-length; the DESCRIBE SDP
// arrives with no length at all. Message text is the pure MoonlightRtsp codec;
// this owns the sockets, the CSeq and the session the host assigned.

import DishCore
import Foundation
import Network

/// What the handshake negotiated: the control port the ENet link dials with
/// the connect token, the media ports the pings keep open (a host may name
/// none for one), and the per-session ping payload.
struct MoonlightStreamPorts: Equatable {
    var controlPort: UInt16
    var videoPort: UInt16?
    var audioPort: UInt16?
    var connectData: UInt32
    var pingPayload: String
}

final class MoonlightRtspClient: @unchecked Sendable {
    static let timeout: TimeInterval = 5

    private let address: String
    private let port: UInt16
    private let queue: DispatchQueue
    private var cseq = 0
    private var sessionId = ""
    private var ports = MoonlightStreamPorts(controlPort: 0, videoPort: nil, audioPort: nil, connectData: 0, pingPayload: "")

    init(address: String, port: UInt16, queue: DispatchQueue = DispatchQueue(label: "dish.moonlight.rtsp")) {
        self.address = address
        self.port = port
        self.queue = queue
    }

    var target: String {
        "rtsp://\(address):\(port)"
    }

    /// The whole handshake in the steps' order; nil at the first step the host
    /// refuses or drops.
    func handshake(config: MoonlightStreamConfig = MoonlightStreamConfig()) async -> MoonlightStreamPorts? {
        for step in MoonlightRtspStep.allCases {
            guard await perform(step, config: config) else { return nil }
        }
        return negotiated
    }

    /// Once every step has passed: the control port is required, the media ports are not.
    var negotiated: MoonlightStreamPorts? {
        ports.controlPort == 0 ? nil : ports
    }

    /// One step, as the session reducer asks for it: true on a 200.
    func perform(_ step: MoonlightRtspStep, config: MoonlightStreamConfig = MoonlightStreamConfig()) async -> Bool {
        cseq += 1
        guard let response = await exchange(request(for: step, cseq: cseq, config: config)), response.ok else { return false }
        absorb(step, response)
        return true
    }

    private func request(for step: MoonlightRtspStep, cseq: Int, config: MoonlightStreamConfig) -> MoonlightRtspRequest {
        switch step {
        case .options: MoonlightRtsp.options(cseq: cseq, target: target)
        case .describe: MoonlightRtsp.describe(cseq: cseq, target: target)
        case .setupAudio: MoonlightRtsp.setup(cseq: cseq, streamId: "audio", sessionId: sessionId)
        case .setupVideo: MoonlightRtsp.setup(cseq: cseq, streamId: "video", sessionId: sessionId)
        case .setupControl: MoonlightRtsp.setup(cseq: cseq, streamId: "control", sessionId: sessionId)
        case .announce: MoonlightRtsp.announce(cseq: cseq, sessionId: sessionId, sdp: MoonlightRtsp.announceSdp(config))
        case .play: MoonlightRtsp.play(cseq: cseq, target: target, sessionId: sessionId)
        }
    }

    /// The facts each SETUP leaves behind: the session the first one named,
    /// the ports, the connect token, the ping payload.
    private func absorb(_ step: MoonlightRtspStep, _ response: MoonlightRtspResponse) {
        if sessionId.isEmpty, let named = response.sessionId() { sessionId = named }
        switch step {
        case .setupAudio:
            ports.audioPort = response.serverPort()
            if ports.pingPayload.isEmpty, let payload = response.pingPayload() { ports.pingPayload = payload }
        case .setupVideo:
            ports.videoPort = response.serverPort()
            if ports.pingPayload.isEmpty, let payload = response.pingPayload() { ports.pingPayload = payload }
        case .setupControl:
            ports.controlPort = response.serverPort() ?? 0
            ports.connectData = response.connectData() ?? 0
        case .options, .describe, .announce, .play:
            break
        }
    }

    /// One request over one connection: connect, write, read until the host
    /// hangs up or Content-length is satisfied, parse.
    private func exchange(_ request: MoonlightRtspRequest) async -> MoonlightRtspResponse? {
        await withCheckedContinuation { continuation in
            let exchange = MoonlightRtspExchange(
                host: address,
                port: port,
                text: request.encode(),
                timeout: Self.timeout,
                queue: queue
            ) { response in
                continuation.resume(returning: response)
            }
            exchange.start()
        }
    }
}

/// One message on one connection, finished exactly once.
private final class MoonlightRtspExchange: @unchecked Sendable {
    private let text: String
    private let timeout: TimeInterval
    private let queue: DispatchQueue
    private let connection: NWConnection
    private let finish: (MoonlightRtspResponse?) -> Void
    private let lock = NSLock()
    private var finished = false
    private var buffer = Data()

    init(
        host: String,
        port: UInt16,
        text: String,
        timeout: TimeInterval,
        queue: DispatchQueue,
        finish: @escaping (MoonlightRtspResponse?) -> Void
    ) {
        self.text = text
        self.timeout = timeout
        self.queue = queue
        self.finish = finish
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = Int(timeout.rounded(.up))
        connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port) ?? .any,
            using: NWParameters(tls: nil, tcp: tcp)
        )
    }

    /// The deadline closure holds the exchange until the reply or the timeout.
    func start() {
        connection.stateUpdateHandler = { [weak self] state in self?.stateChanged(state) }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + timeout) { self.complete(nil) }
    }

    private func stateChanged(_ state: NWConnection.State) {
        switch state {
        case .ready:
            let processed = NWConnection.SendCompletion.contentProcessed { [weak self] error in
                if error != nil { self?.complete(nil) }
            }
            connection.send(content: Data(text.utf8), completion: processed)
            receive()
        case .failed, .cancelled, .waiting:
            // Waiting is where a refused or unroutable connect parks until the
            // network changes; for a host the user named, that is the failure.
            complete(nil)
        case .setup, .preparing:
            break
        @unknown default:
            break
        }
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data { buffer.append(data) }
            if error != nil {
                complete(nil)
                return
            }
            if let response = framed(closed: isComplete) {
                complete(response)
                return
            }
            if isComplete {
                complete(nil)
                return
            }
            receive()
        }
    }

    /// The reply once its head is in and its body is complete: by the length
    /// the host named, or by the hang-up.
    private func framed(closed: Bool) -> MoonlightRtspResponse? {
        guard let text = String(bytes: buffer, encoding: .utf8), let response = MoonlightRtspResponse.parse(text) else { return nil }
        guard buffer.range(of: Data("\r\n\r\n".utf8)) != nil || buffer.range(of: Data("\n\n".utf8)) != nil else { return nil }
        if let length = response.contentLength() {
            return response.payload.utf8.count >= length || closed ? response : nil
        }
        return closed ? response : nil
    }

    private func complete(_ response: MoonlightRtspResponse?) {
        lock.lock()
        let first = !finished
        finished = true
        lock.unlock()
        guard first else { return }
        connection.stateUpdateHandler = nil
        connection.cancel()
        finish(response)
    }
}
