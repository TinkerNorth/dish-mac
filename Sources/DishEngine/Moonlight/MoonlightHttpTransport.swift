// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// One HTTP/1.1 GET over one connection, plain for the pairing phases the
// protocol fixes on the plaintext port, mutual TLS for everything after. A
// connection this opens is one it closes, and TLS session resumption is
// off: a resumed session carries the peer identity forward instead of
// presenting the client certificate again, so the host's verify callback
// never runs and Sunshine answers with a fatal internal_error alert. Never
// throws: every transport, handshake and pin failure is `unreachable`.

import DishCore
import Foundation
import Network
import Security

struct MoonlightHttpReply: Equatable {
    var status: Int
    var body: String

    static let unreachable = MoonlightHttpReply(status: 0, body: "")

    var unreachable: Bool {
        status == 0
    }

    var ok: Bool {
        (200 ... 299).contains(status)
    }
}

/// What a TLS exchange presents and whom it trusts: the leaf certificate's
/// DER is judged by `verifyLeaf` inside the handshake, so a refused host
/// never sees a request.
struct MoonlightTls {
    var identity: SecIdentity?
    var verifyLeaf: @Sendable (Data) -> Bool
}

final class MoonlightHttpTransport {
    static let plainTimeout: TimeInterval = 5
    /// Wider than the plain half: every call pays for its own handshake.
    static let tlsTimeout: TimeInterval = 10
    /// Pairing phase 1: the host answers only once a human has typed the
    /// PIN into its own page. This is the human's window, not the network's.
    static let pinTimeout: TimeInterval = 120

    private let queue = DispatchQueue(label: "dish.moonlight.http", qos: .userInitiated)

    func get(_ request: MoonlightHttpRequest, tls: MoonlightTls?, timeout: TimeInterval) async -> MoonlightHttpReply {
        await withCheckedContinuation { continuation in
            let exchange = MoonlightHttpExchange(request: request, tls: tls, timeout: timeout, queue: queue) { reply in
                continuation.resume(returning: reply)
            }
            exchange.start()
        }
    }
}

/// One request over one connection, finished exactly once: by the reply, the
/// close, the deadline or a failure.
private final class MoonlightHttpExchange: @unchecked Sendable {
    private let request: MoonlightHttpRequest
    private let timeout: TimeInterval
    private let queue: DispatchQueue
    private let connection: NWConnection
    private let finish: (MoonlightHttpReply) -> Void
    private let lock = NSLock()
    private var finished = false
    private var buffer = Data()
    private var head: MoonlightHttpFraming.Head?

    init(
        request: MoonlightHttpRequest,
        tls: MoonlightTls?,
        timeout: TimeInterval,
        queue: DispatchQueue,
        finish: @escaping (MoonlightHttpReply) -> Void
    ) {
        self.request = request
        self.timeout = timeout
        self.queue = queue
        self.finish = finish
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = Int(timeout.rounded(.up))
        let parameters = tls.map { NWParameters(tls: Self.tlsOptions($0, queue: queue), tcp: tcp) } ?? NWParameters(tls: nil, tcp: tcp)
        connection = NWConnection(
            host: NWEndpoint.Host(request.host),
            port: NWEndpoint.Port(rawValue: request.port) ?? .http,
            using: parameters
        )
    }

    /// The deadline closure holds the exchange: nothing else does once `get`
    /// has handed it off, and it has to live until the reply or the timeout.
    func start() {
        connection.stateUpdateHandler = { [weak self] state in self?.stateChanged(state) }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + timeout) { self.complete(.unreachable) }
    }

    /// No resumption, the client identity when there is one, and the leaf
    /// judged by the caller inside the handshake.
    private static func tlsOptions(_ tls: MoonlightTls, queue: DispatchQueue) -> NWProtocolTLS.Options {
        let options = NWProtocolTLS.Options()
        let security = options.securityProtocolOptions
        sec_protocol_options_set_tls_resumption_enabled(security, false)
        sec_protocol_options_set_min_tls_protocol_version(security, .TLSv12)
        if let identity = tls.identity, let object = sec_identity_create(identity) {
            sec_protocol_options_set_local_identity(security, object)
        }
        let verify = tls.verifyLeaf
        let verifyBlock: sec_protocol_verify_t = { _, trust, complete in
            let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
            guard let chain = SecTrustCopyCertificateChain(secTrust) as? [SecCertificate], let leaf = chain.first else {
                complete(false)
                return
            }
            complete(verify(SecCertificateCopyData(leaf) as Data))
        }
        sec_protocol_options_set_verify_block(security, verifyBlock, queue)
        return options
    }

    private func stateChanged(_ state: NWConnection.State) {
        switch state {
        case .ready:
            connection.send(content: MoonlightHttpFraming.requestHead(request), completion: .contentProcessed { [weak self] error in
                if error != nil { self?.complete(.unreachable) }
            })
            receive()
        case .failed, .cancelled:
            complete(.unreachable)
        case .setup, .preparing, .waiting:
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
                complete(.unreachable)
                return
            }
            if let reply = reply(closed: isComplete) {
                complete(reply)
                return
            }
            if isComplete {
                complete(.unreachable)
                return
            }
            receive()
        }
    }

    /// The reply once the head is in and the body is framed complete; nil while more may come.
    private func reply(closed: Bool) -> MoonlightHttpReply? {
        if head == nil {
            guard let parsed = MoonlightHttpFraming.parseHead(buffer) else {
                return MoonlightHttpFraming.headOverflowed(buffer) ? .unreachable : nil
            }
            head = parsed
        }
        guard let head else { return nil }
        let framed = MoonlightHttpFraming.body(MoonlightHttpFraming.framing(head), from: buffer.dropFirst(head.bodyStart), closed: closed)
        guard framed.complete else { return nil }
        return MoonlightHttpReply(status: head.status, body: String(bytes: framed.body, encoding: .utf8) ?? "")
    }

    private func complete(_ reply: MoonlightHttpReply) {
        lock.lock()
        let first = !finished
        finished = true
        lock.unlock()
        guard first else { return }
        connection.stateUpdateHandler = nil
        connection.cancel()
        finish(reply)
    }
}
