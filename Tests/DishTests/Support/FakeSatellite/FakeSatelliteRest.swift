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
    private let connectionId: String
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

    /// contract §Versioning: absent protocolVersion means 1; anything else
    /// (or the reject knob) draws 409 with the supported version.
    func versionRejection(_ body: [String: Any]) -> FakeSatelliteHttp.Response? {
        let version = body["protocolVersion"] as? Int ?? 1
        let knob = store.with { $0.protocolVersionReject }
        guard version != 1 || knob else { return nil }
        return FakeSatelliteHttp.json(409, ["error": "protocol version unsupported", "supported": 1])
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
        let controllers = body["controllers"] as? [[String: Any]] ?? []
        let wantsMouse = (body["hostFeatures"] as? [String: Any])?["mouseControl"] as? Bool ?? false
        let salt = FakeSatelliteRandom.data(8)
        let result = store.with { state -> (response: [String: Any], previous: FakeSatelliteSession?) in
            state.sessionPuts.append(body)
            // Retire the replaced session: old tokens must stop decrypting
            // (the real satellite `extract`s the row; close-notify below
            // still reaches it through the captured object).
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
            let applied = controllers.map { ctrl -> [String: Any] in
                [
                    "ctrlIdx": ctrl["ctrlIdx"] as? Int ?? 0,
                    "result": failure ?? "ok",
                    "appliedType": ctrl["type"] as? Int ?? 0,
                    "motion": ["sinkSupportedForType": true, "backendOk": true]
                ]
            }
            let response: [String: Any] = [
                "connectionId": connectionId,
                "token": String(format: "%08x", token),
                "sessionSalt": FakeSatelliteCrypto.hexString(salt),
                "epoch": Int(state.epoch),
                "maxControllers": 16,
                "protocolVersion": 1,
                "controllers": applied,
                "hostFeatures": ["mouseControl": ["granted": wantsMouse]]
            ]
            return (response, previous)
        }
        // Contract: replacement close-notify goes to the OLD token,
        // best-effort (only when that session ever showed a reply path).
        if let previous = result.previous { udp.sendClose(.replaced, to: previous) }
        let response = FakeSatelliteHttp.json(200, result.response)
        let held = store.with { state -> Bool in
            guard state.holdNextSessionPut else { return false }
            state.holdNextSessionPut = false
            state.heldSessionPuts += 1
            return true
        }
        if held {
            heldLock.lock()
            heldSessionPut = (connection, FakeSatelliteHttp.serialize(response))
            heldLock.unlock()
            return nil
        }
        return response
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

    /// Real sub-routes 404 once the session is closed (or never opened) —
    /// `getSessionView`/`applyController`/`removeController` all report
    /// not-found for a device with no session row.
    private func notFound() -> FakeSatelliteHttp.Response {
        FakeSatelliteHttp.json(404, ["error": "connection not found"])
    }

    private func reconcile(_ request: FakeSatelliteHttp.Request, id: String) -> FakeSatelliteHttp.Response {
        let body = FakeSatelliteHttp.parseJSON(request.body)
        if case let .unauthorized(code) = authenticate(request, body: body) { return unauthorized(code) }
        guard id == connectionId else { return notFound() }
        return store.with { state -> FakeSatelliteHttp.Response in
            guard state.activeToken != nil else { return self.notFound() }
            state.reconcileGets.append(id)
            let controllers = state.controllers.map { ctrl -> [String: Any] in
                var view: [String: Any] = [
                    "ctrlIdx": ctrl["ctrlIdx"] as? Int ?? 0,
                    "active": true,
                    "appliedType": ctrl["type"] as? Int ?? 0,
                    "touchpadMode": ctrl["touchpadMode"] as? String ?? "off",
                    "motion": ["sinkSupportedForType": true, "backendOk": true]
                ]
                if let caps = ctrl["caps"] { view["caps"] = caps }
                return view
            }
            return FakeSatelliteHttp.json(200, [
                "connectionId": id,
                "deviceId": state.pairedDeviceId ?? "",
                "epoch": Int(state.ackEpochOverride ?? state.epoch),
                "protocolVersion": 1,
                "maxControllers": 16,
                "controllers": controllers,
                "hostFeatures": ["mouseControl": ["granted": state.lastMouseGranted]]
            ])
        }
    }

    /// Graceful client close: no close-notify (the closer already knows).
    private func closeSession(_ request: FakeSatelliteHttp.Request, id: String) -> FakeSatelliteHttp.Response {
        let body = FakeSatelliteHttp.parseJSON(request.body)
        if case let .unauthorized(code) = authenticate(request, body: body) { return unauthorized(code) }
        guard id == connectionId else { return notFound() }
        return store.with { state -> FakeSatelliteHttp.Response in
            guard state.activeToken != nil else { return self.notFound() }
            state.sessions.removeAll()
            state.activeToken = nil
            if !state.controllers.isEmpty {
                state.epoch &+= 1
                state.controllers = []
            }
            return FakeSatelliteHttp.json(200, ["ok": true])
        }
    }

    // MARK: - Controller sub-resource (contract §Controller)

    private func putSlot(_ request: FakeSatelliteHttp.Request, id: String, idx: Int) -> FakeSatelliteHttp.Response {
        let body = FakeSatelliteHttp.parseJSON(request.body)
        if case let .unauthorized(code) = authenticate(request, body: body) { return unauthorized(code) }
        guard id == connectionId else { return notFound() }
        return store.with { state -> FakeSatelliteHttp.Response in
            guard state.activeToken != nil else { return self.notFound() }
            var descriptor = body
            descriptor["ctrlIdx"] = idx // the path index wins (contract)
            let existing = state.controllers.firstIndex { ($0["ctrlIdx"] as? Int ?? -1) == idx }
            if let failure = state.controllerApplyFailure {
                // replugFailed leaves the previous pad in force; every other
                // code means the slot is not plugged (contract §Session).
                let priorType = existing.map { state.controllers[$0]["type"] as? Int ?? 0 }
                return FakeSatelliteHttp.json(200, [
                    "epoch": Int(state.epoch),
                    "controller": [
                        "ctrlIdx": idx,
                        "result": failure,
                        "appliedType": priorType ?? (descriptor["type"] as? Int ?? 0),
                        "motion": ["sinkSupportedForType": false, "backendOk": false]
                    ]
                ])
            }
            var list = state.controllers
            if let existing {
                // Epoch moves only on a TYPE change (replug); caps/mode
                // converge in place (`applyDescriptorLocked` same-family arm).
                let typeChanged = (list[existing]["type"] as? Int ?? 0) != (descriptor["type"] as? Int ?? 0)
                if !(list[existing] as NSDictionary).isEqual(to: descriptor) {
                    list[existing] = descriptor
                    if typeChanged { state.epoch &+= 1 }
                }
            } else {
                list.append(descriptor)
                state.epoch &+= 1
            }
            state.controllers = list.sorted { ($0["ctrlIdx"] as? Int ?? 0) < ($1["ctrlIdx"] as? Int ?? 0) }
            return FakeSatelliteHttp.json(200, [
                "epoch": Int(state.epoch),
                "controller": [
                    "ctrlIdx": idx,
                    "result": "ok",
                    "appliedType": descriptor["type"] as? Int ?? 0,
                    "motion": ["sinkSupportedForType": true, "backendOk": true]
                ]
            ])
        }
    }

    /// Removes the SLOT only; the session lives on (contract).
    private func deleteSlot(_ request: FakeSatelliteHttp.Request, id: String, idx: Int) -> FakeSatelliteHttp.Response {
        let body = FakeSatelliteHttp.parseJSON(request.body)
        if case let .unauthorized(code) = authenticate(request, body: body) { return unauthorized(code) }
        guard id == connectionId else { return notFound() }
        return store.with { state -> FakeSatelliteHttp.Response in
            guard state.activeToken != nil else { return self.notFound() }
            let before = state.controllers.count
            state.controllers.removeAll { ($0["ctrlIdx"] as? Int ?? -1) == idx }
            if state.controllers.count != before { state.epoch &+= 1 }
            return FakeSatelliteHttp.json(200, ["ok": true, "epoch": Int(state.epoch)])
        }
    }
}

// MARK: - Catalog & capabilities (contract §ServerInfo & Catalog)

extension FakeSatelliteRest {

    private func catalog(_ request: FakeSatelliteHttp.Request) -> FakeSatelliteHttp.Response {
        store.with { $0.catalogRequests += 1 }
        if request.headers["if-none-match"] == Self.catalogETag {
            return FakeSatelliteHttp.Response(status: 304, headers: [("ETag", Self.catalogETag)], body: Data())
        }
        var response = FakeSatelliteHttp.json(200, raw: Self.catalogJSON)
        response.headers.append(("ETag", Self.catalogETag))
        return response
    }

    static let catalogETag = "\"1.6.0+en\""

    static let capabilitiesJSON = """
    {"protocolVersion":1,"serverVersion":"1.6.0","maxControllers":16,
     "backend":{"id":"fake","supported":true,"available":true,"errorCode":null},
     "motion":{"available":true},
     "host":{"catalog":{"supported":true},
             "mouseControl":{"supported":true,"available":true},
             "keyboardControl":{"supported":false},
             "rumble":{"supported":true,"available":true}}}
    """

    static let catalogJSON = """
    {"locale":"en","protocolVersion":1,"serverVersion":"1.6.0",
     "controllerTypes":[
       {"id":0,"slug":"xbox360","name":"Xbox 360 Controller","shortName":"Xbox",
        "description":"Best compatibility.",
        "image":{"href":"/api/catalog/images/xbox360","etag":"\\"1.6.0\\""},
        "features":{"rumble":{"supported":true},"analogTriggers":{"supported":true},
                    "motion":{"supported":false},"lightbar":{"supported":false},
                    "touchpad":{"supported":false}}},
       {"id":1,"slug":"ds4","name":"DualShock 4","shortName":"PlayStation",
        "description":"Motion, touchpad and light bar.",
        "image":{"href":"/api/catalog/images/ds4","etag":"\\"1.6.0\\""},
        "features":{"rumble":{"supported":true},"analogTriggers":{"supported":true},
                    "motion":{"supported":true},"lightbar":{"supported":true},
                    "touchpad":{"supported":true,"modes":["ds4"]}}},
       {"id":2,"slug":"dualsense","name":"DualSense","shortName":"DualSense",
        "description":"Motion, touchpad and light bar.",
        "image":{"href":"/api/catalog/images/dualsense","etag":"\\"1.6.0\\""},
        "features":{"rumble":{"supported":true},"analogTriggers":{"supported":true},
                    "motion":{"supported":true},"lightbar":{"supported":true},
                    "touchpad":{"supported":true,"modes":["ds4"]}}},
       {"id":3,"slug":"switchpro","name":"Switch Pro","shortName":"Switch Pro",
        "description":"Rumble and motion.",
        "image":{"href":"/api/catalog/images/switchpro","etag":"\\"1.6.0\\""},
        "features":{"rumble":{"supported":true},"analogTriggers":{"supported":false},
                    "motion":{"supported":true},"lightbar":{"supported":false},
                    "touchpad":{"supported":false}}}],
     "hostFeatures":{"mouseControl":{"supported":true,"modes":["off","ds4","mouse"]},
                     "keyboardControl":{"supported":false},
                     "rumble":{"supported":true}}}
    """
}

/// Minimal HTTP/1.1 request parsing + response serialization for the fake.
enum FakeSatelliteHttp {

    struct Request {
        let method: String
        let plainPath: String
        let query: [String: String]
        let headers: [String: String] // keys lowercased
        let body: Data
    }

    struct Response {
        let status: Int
        var headers: [(String, String)]
        let body: Data
    }

    /// Parses one complete request off the front of `buffer`; nil when more
    /// bytes are needed. Returns the request and the consumed byte count.
    static func parseRequest(_ buffer: Data) -> (Request, Int)? {
        guard let headEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        guard let head = String(bytes: buffer[buffer.startIndex ..< headEnd.lowerBound], encoding: .utf8) else { return nil }
        var lines = head.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return nil }
        let method = String(requestLine[0])
        let target = String(requestLine[1])
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        let contentLength = headers["content-length"].flatMap(Int.init) ?? 0
        let bodyStart = headEnd.upperBound
        let available = buffer.distance(from: bodyStart, to: buffer.endIndex)
        guard available >= contentLength else { return nil }
        let body = Data(buffer[bodyStart ..< buffer.index(bodyStart, offsetBy: contentLength)])
        let consumed = buffer.distance(from: buffer.startIndex, to: bodyStart) + contentLength
        let pathAndQuery = target.split(separator: "?", maxSplits: 1)
        let plainPath = String(pathAndQuery[0])
        var query: [String: String] = [:]
        if pathAndQuery.count == 2 {
            for pair in pathAndQuery[1].split(separator: "&") {
                let sides = pair.split(separator: "=", maxSplits: 1)
                guard sides.count == 2 else { continue }
                let key = String(sides[0]).removingPercentEncoding ?? String(sides[0])
                query[key] = String(sides[1]).removingPercentEncoding ?? String(sides[1])
            }
        }
        return (Request(method: method, plainPath: plainPath, query: query, headers: headers, body: body), consumed)
    }

    static func serialize(_ response: Response) -> Data {
        var head = "HTTP/1.1 \(response.status) \(reasonPhrase(response.status))\r\n"
        for (name, value) in response.headers {
            head += "\(name): \(value)\r\n"
        }
        head += "Content-Length: \(response.body.count)\r\n\r\n"
        return Data(head.utf8) + response.body
    }

    static func json(_ status: Int, _ object: [String: Any]) -> Response {
        let body = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        return Response(status: status, headers: [("Content-Type", "application/json")], body: body)
    }

    static func json(_ status: Int, raw: String) -> Response {
        Response(status: status, headers: [("Content-Type", "application/json")], body: Data(raw.utf8))
    }

    static func parseJSON(_ data: Data) -> [String: Any] {
        guard !data.isEmpty else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    static func reasonPhrase(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 304: "Not Modified"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 404: "Not Found"
        case 409: "Conflict"
        case 503: "Service Unavailable"
        default: "Status"
        }
    }
}
