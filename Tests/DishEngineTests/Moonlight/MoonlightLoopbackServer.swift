// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// A loopback HTTP/1.1 server for the Moonlight transport tests: one canned
// answer per path, plain or TLS, and with TLS the client certificate the
// peer presented recorded, so mutual TLS is exercised end to end without a
// host. Each connection is answered once and closed, as a Moonlight host
// answers.

import Foundation
import Network
import Security

final class MoonlightLoopbackServer: @unchecked Sendable {
    enum Answer {
        case bytes(Data)
        case slow
        case closeWithoutAnswer
    }

    private let lock = NSLock()
    private var answers: [String: Answer] = [:]
    private var responder: ((String) -> Answer?)?
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private(set) var clientCertificates: [Data] = []
    private(set) var requests: [String] = []
    private let queue = DispatchQueue(label: "dish.test.moonlight-loopback")
    private(set) var port: UInt16 = 0

    func answer(_ path: String, _ answer: Answer) {
        lock.lock()
        answers[path] = answer
        lock.unlock()
    }

    func answer(_ path: String, status: Int, body: String, headers: [String] = []) {
        answer(path, Self.httpAnswer(status: status, body: body, headers: headers))
    }

    /// An answer computed from the request target (path and query), asked
    /// before the canned answers; nil falls through to them.
    func respond(_ responder: @escaping (String) -> Answer?) {
        lock.lock()
        self.responder = responder
        lock.unlock()
    }

    static func httpAnswer(status: Int, body: String, headers: [String] = []) -> Answer {
        let head = ["HTTP/1.1 \(status) OK", "Content-Length: \(body.utf8.count)"] + headers
        return .bytes(Data((head.joined(separator: "\r\n") + "\r\n\r\n" + body).utf8))
    }

    /// Plain, or TLS with `identity`; with `requireClientCertificate` the
    /// peer must present one and it is recorded.
    func start(identity: SecIdentity? = nil, requireClientCertificate: Bool = false) throws -> UInt16 {
        let params: NWParameters
        if let identity, let object = sec_identity_create(identity) {
            let tls = NWProtocolTLS.Options()
            let security = tls.securityProtocolOptions
            sec_protocol_options_set_local_identity(security, object)
            if requireClientCertificate {
                sec_protocol_options_set_peer_authentication_required(security, true)
                let verify: sec_protocol_verify_t = { [weak self] _, trust, complete in
                    let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
                    if let chain = SecTrustCopyCertificateChain(secTrust) as? [SecCertificate], let leaf = chain.first {
                        self?.record(SecCertificateCopyData(leaf) as Data)
                    }
                    complete(true)
                }
                sec_protocol_options_set_verify_block(security, verify, queue)
            }
            params = NWParameters(tls: tls)
        } else {
            params = .tcp
        }
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

    private func record(_ certificate: Data) {
        lock.lock()
        clientCertificates.append(certificate)
        lock.unlock()
    }

    private func receive(_ connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffered
            if let data { buffer.append(data) }
            if error != nil || isComplete { return }
            guard let headEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                receive(connection, buffered: buffer)
                return
            }
            let head = String(bytes: buffer[..<headEnd.lowerBound], encoding: .utf8) ?? ""
            let target = head.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            let path = target.split(separator: "?").first.map(String.init) ?? target
            lock.lock()
            requests.append(target)
            let canned = answers[path]
            let responder = responder
            lock.unlock()
            let answer = responder?(target) ?? canned
            switch answer {
            case let .bytes(bytes):
                connection.send(content: bytes, completion: .contentProcessed { _ in connection.cancel() })
            case .closeWithoutAnswer, nil:
                connection.cancel()
            case .slow:
                break
            }
        }
    }
}
