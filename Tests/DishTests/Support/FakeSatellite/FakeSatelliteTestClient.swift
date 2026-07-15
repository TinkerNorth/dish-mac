// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// Scripted protocol-1 clients for the FakeSatellite SELF-tests: a URLSession
// REST client pinned to the harness certificate (the same DER compare a TOFU
// delegate performs) and a raw NWConnection UDP client that seals/opens
// datagrams with FakeSatelliteCrypto. Wave-3 integration tests drive the
// REAL app against the harness instead; these exist to prove the harness.

import CryptoKit
import Foundation
import Network

enum FakeSatelliteScriptFailure: Error {
    case badURL
    case notHTTP
    case missingField(String)
}

/// REST script client. When `pinnedDER` is set (https transport), the server
/// leaf certificate must byte-match it or the request fails and
/// `certificateMismatches` increments — the imposter-test observable.
final class FakeSatelliteRestScriptClient: NSObject, URLSessionDelegate {

    struct Reply {
        let status: Int
        let headers: [String: String] // keys lowercased
        let json: [String: Any]
        let body: Data

        func string(_ key: String) -> String? {
            json[key] as? String
        }

        func int(_ key: String) -> Int? {
            json[key] as? Int
        }

        func bool(_ key: String) -> Bool? {
            json[key] as? Bool
        }

        func dict(_ key: String) -> [String: Any]? {
            json[key] as? [String: Any]
        }

        func array(_ key: String) -> [[String: Any]]? {
            json[key] as? [[String: Any]]
        }
    }

    private let scheme: String
    private let port: UInt16
    private let pinnedDER: Data?
    private let mismatchLock = NSLock()
    private var mismatches = 0

    var certificateMismatches: Int {
        mismatchLock.lock()
        defer { mismatchLock.unlock() }
        return mismatches
    }

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 20
        // No transparent caching: conditional-GET tests must observe the real
        // wire status (an in-memory URLCache would replay the 200 itself).
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    /// Pins to `satellite`'s own certificate — the trusting-client setup.
    convenience init(satellite: FakeSatellite) {
        self.init(
            port: satellite.ports?.rest ?? 0,
            https: satellite.transport == .https,
            pinnedDER: satellite.certificateDER
        )
    }

    init(port: UInt16, https: Bool, pinnedDER: Data?) {
        scheme = https ? "https" : "http"
        self.port = port
        self.pinnedDER = https ? pinnedDER : nil
        super.init()
    }

    func request(
        _ method: String,
        _ path: String,
        json: [String: Any]? = nil,
        headers: [String: String] = [:]
    ) async throws -> Reply {
        guard let url = URL(string: "\(scheme)://127.0.0.1:\(port)\(path)") else {
            throw FakeSatelliteScriptFailure.badURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        if let json {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw FakeSatelliteScriptFailure.notHTTP }
        var headerMap: [String: String] = [:]
        for (name, value) in http.allHeaderFields {
            headerMap[String(describing: name).lowercased()] = String(describing: value)
        }
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return Reply(status: http.statusCode, headers: headerMap, json: object, body: data)
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first else
        {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        let leafDER = SecCertificateCopyData(leaf) as Data
        if let pinnedDER, leafDER != pinnedDER {
            mismatchLock.lock()
            mismatches += 1
            mismatchLock.unlock()
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}

/// Raw UDP script client with a bounded-wait inbox (no polling sleeps).
final class FakeSatelliteUdpScriptClient {

    struct DownFrame {
        let opcode: UInt16
        let counter: UInt32
        let payload: Data
    }

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "fake-satellite.script-udp")
    private let condition = NSCondition()
    private var inbox: [Data] = []

    init(port: UInt16) {
        let endpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port) ?? .any)
        connection = NWConnection(to: endpoint, using: .udp)
        connection.start(queue: queue)
        receiveLoop()
    }

    private func receiveLoop() {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            self.condition.lock()
            if let data, !data.isEmpty { self.inbox.append(data) }
            self.condition.broadcast()
            self.condition.unlock()
            if error == nil { self.receiveLoop() }
        }
    }

    func send(_ datagram: Data) {
        connection.send(content: datagram, completion: .contentProcessed { _ in })
    }

    /// Seals one uplink frame per the contract packet format and sends it.
    func sendFrame(
        opcode: UInt16,
        payload: Data,
        key: SymmetricKey,
        token: UInt32,
        counter: UInt32,
        direction: FakeSatelliteCrypto.Direction = .clientToServer,
        aadToken: UInt32? = nil
    ) throws {
        let inner = FakeSatelliteCrypto.encodeInner(msgType: opcode, payload: payload)
        let box = try FakeSatelliteCrypto.seal(
            inner,
            key: key,
            direction: direction,
            counter: counter,
            token: aadToken ?? token
        )
        send(FakeSatelliteCrypto.tokenBE(token) + FakeSatelliteCrypto.be32(counter) + box)
    }

    /// Bounded FIFO wait for the next raw datagram.
    func awaitDatagram(timeout: TimeInterval = 5) -> Data? {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        while inbox.isEmpty {
            if !condition.wait(until: deadline) { break }
        }
        guard !inbox.isEmpty else { return nil }
        return inbox.removeFirst()
    }

    /// Awaits the next downlink datagram and opens it as server→client.
    func awaitDownFrame(key: SymmetricKey, token: UInt32, timeout: TimeInterval = 5) -> DownFrame? {
        guard let datagram = awaitDatagram(timeout: timeout),
              let header = FakeSatelliteCrypto.parseDatagram(datagram),
              header.token == token,
              let inner = try? FakeSatelliteCrypto.open(
                  header.box,
                  key: key,
                  direction: .serverToClient,
                  counter: header.counter,
                  token: header.token
              ),
              let frame = FakeSatelliteCrypto.parseInner(inner) else { return nil }
        return DownFrame(opcode: frame.msgType, counter: header.counter, payload: Data(frame.payload))
    }

    func stop() {
        connection.cancel()
    }
}

/// Shared scripted flows so the single self-test file stays compact.
enum FakeSatelliteScript {

    struct SessionContext {
        let deviceId: String
        let pairingKey: Data
        let proofHex: String
        let token: UInt32
        let sessionKey: SymmetricKey
        let connectionId: String
        let epoch: Int
    }

    /// Path-A pairing: POST the operator PIN, returns the minted pairing key.
    static func pairOperator(
        _ rest: FakeSatelliteRestScriptClient,
        deviceId: String,
        pin: String = "1234"
    ) async throws -> Data {
        let reply = try await rest.request("POST", "/api/pair", json: [
            "deviceId": deviceId,
            "deviceName": "self-test",
            "pin": pin,
            "protocolVersion": 1
        ])
        guard reply.status == 200, reply.bool("ok") == true,
              let keyHex = reply.string("sharedKey"),
              let key = FakeSatelliteCrypto.hexToData(keyHex) else
        {
            throw FakeSatelliteScriptFailure.missingField("sharedKey")
        }
        return key
    }

    /// Declarative session PUT; derives the session key exactly as a real
    /// client must (HKDF over pairingKey/salt/token from the response).
    static func putSession(
        _ rest: FakeSatelliteRestScriptClient,
        deviceId: String,
        pairingKey: Data,
        controllers: [[String: Any]],
        hostFeatures: [String: Any] = [:]
    ) async throws -> SessionContext {
        let proof = FakeSatelliteCrypto.hmacProofHex(pairingKey: pairingKey, deviceId: deviceId)
        let reply = try await rest.request(
            "PUT",
            "/api/connections",
            json: [
                "deviceId": deviceId,
                "deviceName": "self-test",
                "protocolVersion": 1,
                "hmacProof": proof,
                "controllers": controllers,
                "hostFeatures": hostFeatures
            ],
            headers: ["X-Device-Id": deviceId, "X-Hmac-Proof": proof]
        )
        guard reply.status == 200,
              let tokenHex = reply.string("token"),
              let token = UInt32(tokenHex, radix: 16),
              let saltHex = reply.string("sessionSalt"),
              let salt = FakeSatelliteCrypto.hexToData(saltHex),
              let connectionId = reply.string("connectionId"),
              let epoch = reply.int("epoch") else
        {
            throw FakeSatelliteScriptFailure.missingField("token/sessionSalt/connectionId/epoch")
        }
        return SessionContext(
            deviceId: deviceId,
            pairingKey: pairingKey,
            proofHex: proof,
            token: token,
            sessionKey: FakeSatelliteCrypto.deriveSessionKey(pairingKey: pairingKey, salt: salt, token: token),
            connectionId: connectionId,
            epoch: epoch
        )
    }
}
