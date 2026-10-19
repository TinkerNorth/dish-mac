// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// A loopback RTSP host for the handshake tests: one message per connection
// and then the hang-up, as a Moonlight host does, with a scripted reply per
// command and every request recorded. Plus a loopback UDP listener that
// records what reaches it and can echo it back.

import Foundation
import Network

final class MoonlightLoopbackRtspHost: @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [String: String] = [:]
    private var hangUpOn: Set<String> = []
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private(set) var requests: [String] = []
    private let queue = DispatchQueue(label: "dish.test.rtsp-host")
    private(set) var port: UInt16 = 0

    /// Sunshine's shapes: ports 47999 / 47998 / 48000, the connect token and
    /// the ping payload a live host handed dish-android.
    static func sunshineLike() -> MoonlightLoopbackRtspHost {
        let host = MoonlightLoopbackRtspHost()
        let session = "Session: DEADBEEFCAFE;timeout = 90\r\n"
        host.reply("OPTIONS", "RTSP/1.0 200 OK\r\nCSeq: 1\r\nPublic: DESCRIBE, SETUP, TEARDOWN, PLAY\r\n\r\n")
        host.reply("DESCRIBE", "RTSP/1.0 200 OK\r\nCSeq: 2\r\n\r\nv=0\r\na=fmtp:97 surround-params=21101\r\n")
        host.reply(
            "SETUP streamid=audio",
            "RTSP/1.0 200 OK\r\nCSeq: 3\r\n" + session + "Transport: server_port=48000\r\nX-SS-Ping-Payload: 9A615601970AEC19\r\n\r\n"
        )
        host.reply("SETUP streamid=video", "RTSP/1.0 200 OK\r\nCSeq: 4\r\n" + session + "Transport: server_port=47998\r\n\r\n")
        host.reply(
            "SETUP streamid=control",
            "RTSP/1.0 200 OK\r\nCSeq: 5\r\n" + session + "Transport: server_port=47999\r\nX-SS-Connect-Data: 4270471497\r\n\r\n"
        )
        host.reply("ANNOUNCE", "RTSP/1.0 200 OK\r\nCSeq: 6\r\n\r\n")
        host.reply("PLAY", "RTSP/1.0 200 OK\r\nCSeq: 7\r\n\r\n")
        return host
    }

    func reply(_ commandPrefix: String, _ text: String) {
        lock.lock()
        replies[commandPrefix] = text
        lock.unlock()
    }

    /// Hang up without answering a command that starts with this prefix.
    func hangUp(on commandPrefix: String) {
        lock.lock()
        hangUpOn.insert(commandPrefix)
        lock.unlock()
    }

    func start() throws -> UInt16 {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: params)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else {
                connection.cancel()
                return
            }
            lock.lock()
            connections.append(connection)
            lock.unlock()
            connection.start(queue: queue)
            receive(connection, buffered: Data())
        }
        port = try FakeSatelliteNet.startAndAwaitReady(listener, queue: queue)
        self.listener = listener
        return port
    }

    func stop() {
        listener?.cancel()
        lock.lock()
        let open = connections
        connections = []
        lock.unlock()
        open.forEach { $0.cancel() }
    }

    private func receive(_ connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffered
            if let data { buffer.append(data) }
            if error != nil || isComplete { return }
            guard let text = String(bytes: buffer, encoding: .utf8), let headEnd = text.range(of: "\r\n\r\n") else {
                receive(connection, buffered: buffer)
                return
            }
            // An ANNOUNCE carries its SDP after the blank line; wait for the length it names.
            if let length = contentLength(text), text[headEnd.upperBound...].utf8.count < length {
                receive(connection, buffered: buffer)
                return
            }
            answer(connection, request: text)
        }
    }

    private func answer(_ connection: NWConnection, request: String) {
        let line = request.split(separator: "\r\n").first.map(String.init) ?? ""
        lock.lock()
        requests.append(request)
        let hangUp = hangUpOn.contains { line.hasPrefix($0) }
        let reply = replies.first { line.hasPrefix($0.key) }?.value
        lock.unlock()
        guard !hangUp, let reply else {
            connection.cancel()
            return
        }
        connection.send(content: Data(reply.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }

    private func contentLength(_ text: String) -> Int? {
        text.split(separator: "\r\n").first { $0.lowercased().hasPrefix("content-length:") }
            .flatMap { Int($0.split(separator: ":").last?.trimmingCharacters(in: .whitespaces) ?? "") }
    }
}

/// A loopback UDP listener that records every datagram and can echo it back.
final class MoonlightLoopbackUdp: @unchecked Sendable {
    private let lock = NSLock()
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private(set) var received: [Data] = []
    private let echo: Bool
    private let queue = DispatchQueue(label: "dish.test.udp")
    private(set) var port: UInt16 = 0

    init(echo: Bool = false) {
        self.echo = echo
    }

    func start() throws -> UInt16 {
        let params = NWParameters.udp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: params)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else {
                connection.cancel()
                return
            }
            lock.lock()
            connections.append(connection)
            lock.unlock()
            connection.start(queue: queue)
            receive(connection)
        }
        port = try FakeSatelliteNet.startAndAwaitReady(listener, queue: queue)
        self.listener = listener
        return port
    }

    func stop() {
        listener?.cancel()
        lock.lock()
        let open = connections
        connections = []
        lock.unlock()
        open.forEach { $0.cancel() }
    }

    func count() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return received.count
    }

    func datagrams() -> [Data] {
        lock.lock()
        defer { lock.unlock() }
        return received
    }

    private func receive(_ connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self, error == nil else { return }
            if let data {
                lock.lock()
                received.append(data)
                lock.unlock()
                if echo { connection.send(content: data, completion: .contentProcessed { _ in }) }
            }
            receive(connection)
        }
    }
}
