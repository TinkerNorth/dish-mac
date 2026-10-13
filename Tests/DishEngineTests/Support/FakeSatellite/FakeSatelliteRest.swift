// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// FakeSatellite REST control plane (contract §Pairing / §Session /
// §Controller / §ServerInfo & Catalog / §Versioning / §Error model).
//
// A tiny HTTP/1.1 server over NWListener with keep-alive. Transport is TLS
// with the instance's runtime-minted identity when a SecIdentity could be
// assembled headlessly, else plain HTTP (`transport` reports which; TOFU
// tests always have `certificateDER`). Routes implemented: POST/DELETE
// /api/pair, GET /api/pair/status, PUT /api/connections, GET/DELETE
// /api/connections/{id}, PUT/DELETE /api/connections/{id}/controllers/{idx},
// GET /api/server/capabilities, GET /api/catalog (ETag/304).

import Foundation
import Network

final class FakeSatelliteRest {

    let store: FakeSatelliteStore
    private let identity: FakeSatelliteIdentity
    let udp: FakeSatelliteUdp
    let operatorPin: String
    let connectionId: String
    private let queue = DispatchQueue(label: "fake-satellite.rest")
    private var listener: NWListener?
    private let connectionsLock = NSLock()
    private var connections: [NWConnection] = []
    /// Parked (connection, serialized response) slots for the hold knobs:
    /// the request is processed normally, only the response delivery waits
    /// for the matching release call.
    let heldLock = NSLock()
    private var heldSessionPut: (NWConnection, Data)?
    var heldPair: (NWConnection, Data)?
    private(set) var transport: FakeSatellite.Transport = .http
    private(set) var port: UInt16 = 0

    init(
        store: FakeSatelliteStore,
        identity: FakeSatelliteIdentity,
        udp: FakeSatelliteUdp,
        operatorPin: String,
        connectionId: String
    ) {
        self.store = store
        self.identity = identity
        self.udp = udp
        self.operatorPin = operatorPin
        self.connectionId = connectionId
    }

    // MARK: - Lifecycle

    @discardableResult
    func start() throws -> UInt16 {
        if let secIdentity = identity.secIdentity(), let identityObject = sec_identity_create(secIdentity) {
            let tls = NWProtocolTLS.Options()
            sec_protocol_options_set_local_identity(tls.securityProtocolOptions, identityObject)
            if let httpsPort = try? startListener(with: NWParameters(tls: tls)) {
                transport = .https
                port = httpsPort
                return httpsPort
            }
        }
        // Keychain-refusing runner: without a SecIdentity there is no TLS
        // listener, and every https-only app suite would fail as a misleading
        // "unreachable". Say so loudly; those suites XCTSkip via
        // `requireHTTPSTransport()`.
        print("FakeSatellite: SecIdentity unavailable (keychain refused) — serving PLAIN HTTP; https-only app suites will skip")
        let httpPort = try startListener(with: .tcp)
        transport = .http
        port = httpPort
        return httpPort
    }

    func stop() {
        listener?.cancel()
        listener = nil
        heldLock.lock()
        heldSessionPut = nil
        heldPair = nil
        heldLock.unlock()
        connectionsLock.lock()
        let open = connections
        connections = []
        connectionsLock.unlock()
        open.forEach { $0.cancel() }
    }

    /// Deliver the parked session-PUT response. False when nothing is parked.
    @discardableResult
    func releaseHeldSessionPut() -> Bool {
        heldLock.lock()
        let parked = heldSessionPut
        heldSessionPut = nil
        heldLock.unlock()
        guard let (connection, data) = parked else { return false }
        connection.send(content: data, completion: .contentProcessed { _ in })
        return true
    }

    /// Deliver the parked pair response. False when nothing is parked.
    @discardableResult
    func releaseHeldPair() -> Bool {
        heldLock.lock()
        let parked = heldPair
        heldPair = nil
        heldLock.unlock()
        guard let (connection, data) = parked else { return false }
        connection.send(content: data, completion: .contentProcessed { _ in })
        return true
    }

    private func startListener(with params: NWParameters) throws -> UInt16 {
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: params)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else {
                connection.cancel()
                return
            }
            self.connectionsLock.lock()
            self.connections.append(connection)
            self.connectionsLock.unlock()
            connection.start(queue: self.queue)
            self.receive(on: connection, buffered: Data())
        }
        let boundPort = try FakeSatelliteNet.startAndAwaitReady(listener, queue: queue)
        self.listener = listener
        return boundPort
    }

    private func receive(on connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffered
            if let data { buffer.append(data) }
            while let (request, consumed) = FakeSatelliteHttp.parseRequest(buffer) {
                buffer.removeFirst(consumed)
                // nil = the response was parked by the hold knob.
                guard let response = self.route(request, on: connection) else { continue }
                connection.send(content: FakeSatelliteHttp.serialize(response), completion: .contentProcessed { _ in })
            }
            if error != nil || isComplete {
                connection.cancel()
                return
            }
            self.receive(on: connection, buffered: buffer)
        }
    }

    // MARK: - Routing

    private func route(_ request: FakeSatelliteHttp.Request, on connection: NWConnection) -> FakeSatelliteHttp.Response? {
        switch (request.method, request.plainPath) {
        case ("POST", "/api/pair"): return pair(request, on: connection)
        case ("GET", "/api/pair/status"): return pairStatus(request)
        case ("DELETE", "/api/pair"): return selfUnpair(request)
        case ("PUT", "/api/connections"): return putSession(request, on: connection)
        case ("GET", "/api/server/capabilities"): return FakeSatelliteHttp.json(200, raw: Self.capabilitiesJSON)
        case ("GET", "/api/catalog"): return catalog(request)
        default:
            if request.plainPath.hasPrefix("/api/connections/") { return connectionSubroute(request) }
            return FakeSatelliteHttp.json(404, ["error": "unknown route"])
        }
    }

    private func connectionSubroute(_ request: FakeSatelliteHttp.Request) -> FakeSatelliteHttp.Response {
        let tail = request.plainPath.dropFirst("/api/connections/".count)
        let parts = tail.split(separator: "/").map(String.init)
        switch (request.method, parts.count) {
        case ("GET", 1): return reconcile(request, id: parts[0])
        case ("DELETE", 1): return closeSession(request, id: parts[0])
        case ("PUT", 3) where parts[1] == "controllers":
            guard let idx = Int(parts[2]) else { return FakeSatelliteHttp.json(400, ["error": "bad ctrlIdx"]) }
            return putSlot(request, id: parts[0], idx: idx)
        case ("DELETE", 3) where parts[1] == "controllers":
            guard let idx = Int(parts[2]) else { return FakeSatelliteHttp.json(400, ["error": "bad ctrlIdx"]) }
            return deleteSlot(request, id: parts[0], idx: idx)
        default:
            return FakeSatelliteHttp.json(404, ["error": "unknown route"])
        }
    }

    // MARK: - Auth (contract §hmacProof / §Error model)

    enum AuthOutcome {
        case ok(deviceId: String)
        case unauthorized(code: String)
    }

    /// Header wins over body when both carry credentials (contract). Scoped
    /// to the paired device like the real `clientAuthed`: an unknown deviceId
    /// draws NOT_PAIRED regardless of proof. A pre-seeded key (the
    /// `pairingKeyHex` knob) has no device row yet, so the first deviceId
    /// that proves key possession is adopted as the paired device.
    func authenticate(_ request: FakeSatelliteHttp.Request, body: [String: Any]) -> AuthOutcome {
        let suppliedId = request.headers["x-device-id"] ?? body["deviceId"] as? String
        let proof = request.headers["x-hmac-proof"] ?? body["hmacProof"] as? String
        return store.with { state -> AuthOutcome in
            if let forced = state.forced401Code {
                return .unauthorized(code: forced)
            }
            guard let keyHex = state.pairingKeyHex,
                  let key = FakeSatelliteCrypto.hexToData(keyHex),
                  let deviceId = suppliedId, !deviceId.isEmpty else
            {
                return .unauthorized(code: "NOT_PAIRED")
            }
            if let paired = state.pairedDeviceId, paired != deviceId {
                return .unauthorized(code: "NOT_PAIRED")
            }
            guard let proof,
                  FakeSatelliteCrypto.verifyHmacProof(pairingKey: key, deviceId: deviceId, proofHex: proof) else
            {
                return .unauthorized(code: "BAD_PROOF")
            }
            if state.pairedDeviceId == nil { state.pairedDeviceId = deviceId }
            return .ok(deviceId: deviceId)
        }
    }

    func unauthorized(_ code: String) -> FakeSatelliteHttp.Response {
        FakeSatelliteHttp.json(401, ["error": "unauthorized", "code": code])
    }

    /// contract §Versioning: an offer inside [supportedMin, supported]
    /// settles the session on it and is echoed back; absent means 1; an
    /// offer outside the range draws 409 with both bounds.
    func versionRejection(_ body: [String: Any]) -> FakeSatelliteHttp.Response? {
        let offered = body["protocolVersion"] as? Int ?? 1
        let range = store.with { $0.supportedProtocolMin ... $0.supportedProtocol }
        guard !range.contains(offered) else {
            store.with { $0.settledProtocolVersion = offered }
            return nil
        }
        store.with { $0.rejectedOffers.append(offered) }
        return FakeSatelliteHttp.json(409, [
            "error": "protocol version unsupported",
            "supported": range.upperBound,
            "supportedMin": range.lowerBound
        ])
    }

    // MARK: - Session (contract §Session)

    private func putSession(_ request: FakeSatelliteHttp.Request, on connection: NWConnection) -> FakeSatelliteHttp.Response? {
        let body = FakeSatelliteHttp.parseJSON(request.body)
        // Real route order (upsertConnectionRoute): shutting-down 503 first,
        // then auth, then version.
        if store.with({ $0.shuttingDown }) {
            return FakeSatelliteHttp.json(503, ["error": "shutting down"])
        }
        if case let .unauthorized(code) = authenticate(request, body: body) { return unauthorized(code) }
        if let rejection = versionRejection(body) { return rejection }
        guard let keyHex = store.with({ $0.pairingKeyHex }),
              let pairingKey = FakeSatelliteCrypto.hexToData(keyHex) else
        {
            return unauthorized("NOT_PAIRED")
        }
        let minted = mintSession(body: body, pairingKey: pairingKey)
        // Contract: replacement close-notify goes to the OLD token,
        // best-effort (only when that session ever showed a reply path).
        if let previous = minted.previous { udp.sendClose(.replaced, to: previous) }
        return respondOrHold(FakeSatelliteHttp.json(200, minted.response), on: connection)
    }

    /// Rotate the token, salt and key, apply the controllers, bump the epoch
    /// on a topology change and retire the replaced session: old tokens must
    /// stop decrypting.
    private func mintSession(body: [String: Any], pairingKey: Data) -> (response: [String: Any], previous: FakeSatelliteSession?) {
        let controllers = body["controllers"] as? [[String: Any]] ?? []
        let wantsMouse = (body["hostFeatures"] as? [String: Any])?["mouseControl"] as? Bool ?? false
        let salt = FakeSatelliteRandom.data(8)
        return store.with { state -> (response: [String: Any], previous: FakeSatelliteSession?) in
            state.sessionPuts.append(body)
            let previous = state.activeToken.flatMap { state.sessions.removeValue(forKey: $0) }
            let failure = state.controllerApplyFailure
            if failure == nil {
                if !Self.sameTopology(state.controllers, controllers) { state.epoch &+= 1 }
                state.controllers = controllers
            }
            state.lastMouseGranted = wantsMouse
            state.tokenCounter &+= 1
            let token = state.tokenCounter
            state.lastSessionSaltHex = FakeSatelliteCrypto.hexString(salt)
            let session = FakeSatelliteSession(
                token: token,
                key: FakeSatelliteCrypto.deriveSessionKey(pairingKey: pairingKey, salt: salt, token: token)
            )
            state.sessions[token] = session
            state.activeToken = token
            let response: [String: Any] = [
                "connectionId": connectionId,
                "token": String(format: "%08x", token),
                "sessionSalt": FakeSatelliteCrypto.hexString(salt),
                "epoch": Int(state.epoch),
                "maxControllers": 16,
                "protocolVersion": state.settledProtocolVersion,
                "controllers": Self.appliedControllers(controllers, failure: failure),
                "hostFeatures": ["mouseControl": ["granted": wantsMouse]]
            ]
            return (response, previous)
        }
    }

    /// Every requested descriptor's apply result: the failure knob's code, or
    /// `ok`.
    private static func appliedControllers(_ controllers: [[String: Any]], failure: String?) -> [[String: Any]] {
        controllers.map { ctrl -> [String: Any] in
            [
                "ctrlIdx": ctrl["ctrlIdx"] as? Int ?? 0,
                "result": failure ?? "ok",
                "appliedType": ctrl["type"] as? Int ?? 0,
                "motion": ["sinkSupportedForType": true, "backendOk": true]
            ]
        }
    }

    /// The hold knob parks the serialized response until a release call;
    /// nil tells the receive loop nothing is to be sent now.
    private func respondOrHold(_ response: FakeSatelliteHttp.Response, on connection: NWConnection) -> FakeSatelliteHttp.Response? {
        let held = store.with { state -> Bool in
            guard state.holdNextSessionPut else { return false }
            state.holdNextSessionPut = false
            state.heldSessionPuts += 1
            return true
        }
        guard held else { return response }
        heldLock.lock()
        heldSessionPut = (connection, FakeSatelliteHttp.serialize(response))
        heldLock.unlock()
        return nil
    }

    /// Applied topology = the (ctrlIdx → type) map. Caps/touchpadMode
    /// converge in place with NO epoch bump (`applyDescriptorLocked`'s
    /// same-family arm); only slot-set and type changes move the epoch.
    private static func sameTopology(_ old: [[String: Any]], _ new: [[String: Any]]) -> Bool {
        func keyed(_ list: [[String: Any]]) -> [Int: Int] {
            var out: [Int: Int] = [:]
            for ctrl in list {
                out[ctrl["ctrlIdx"] as? Int ?? 0] = ctrl["type"] as? Int ?? 0
            }
            return out
        }
        return keyed(old) == keyed(new)
    }
}
