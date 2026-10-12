// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.

import CryptoKit
import DishCore
import Foundation

extension WifiConnectionManager {

    /// The session PUT's grant, decoded as far as the control plane needs:
    /// the connection id and the HKDF inputs.
    struct SessionGrant: Equatable {
        let connectionId: String
        let tokenHex: String
        let saltHex: String
    }

    /// How a session PUT response is acted on.
    enum OpenOutcome: Equatable {
        case unauthorized
        case versionMismatch
        case refused
        case granted(SessionGrant)
    }

    /// Classify a session PUT response. The terminal 401 and 409 outcomes
    /// come first; a reachable reply with the three grant fields is a grant;
    /// anything else is a refusal.
    nonisolated static func classifyOpen(_ resp: SessionResponse) -> OpenOutcome {
        let unauthorized = resp.unauthorized || resp.verdict == .unauthorized
        if unauthorized { return .unauthorized }
        if resp.verdict == .versionMismatch { return .versionMismatch }
        guard resp.reachable,
              let connectionId = resp.connectionId,
              let tokenHex = resp.token,
              let saltHex = resp.sessionSalt else { return .refused }
        return .granted(SessionGrant(connectionId: connectionId, tokenHex: tokenHex, saltHex: saltHex))
    }

    /// Derive the session key from a grant's token and salt hex:
    /// `HKDF-SHA256(pairingKey, sessionSalt, "satellite-session-v1" || token)`.
    /// Nil on malformed hex, which no retry can fix.
    nonisolated static func sessionMaterial(
        tokenHex: String,
        saltHex: String,
        pairingKey: Data
    ) -> (token: UInt32, key: SymmetricKey)? {
        guard let tokenData = hexToBytes(tokenHex), tokenData.count == 4,
              let saltData = hexToBytes(saltHex),
              saltData.count == ProtocolConstants.sessionSaltSize else { return nil }
        let token = tokenData.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        let key = SessionCrypto.deriveSessionKey(pairingKey: pairingKey, salt: saltData, token: token)
        return (token, key)
    }

    // MARK: - Open

    /// One declarative `PUT /api/connections` with the whole desired
    /// controller set, then the HKDF key handoff to a fresh UDP client. The
    /// pairing key never reaches the data plane.
    func openSession(conn: WifiConnection, server: DiscoveredServer, intent: ConnectIntent) async {
        let id = WifiConnection.idFor(server)
        guard let pairingKey = pairingKeyData(for: id) else {
            failOpenWithoutKey(conn, id: id, intent: intent)
            return
        }
        let descriptors = conn.desiredDescriptor.map { [$0] } ?? []
        let resp = await putSession(server: server, pairingKey: pairingKey, controllers: descriptors)
        switch Self.classifyOpen(resp) {
        case .unauthorized:
            handleTerminalAuth(id, loud: intent == .userInitiated)
        case .versionMismatch:
            conn.markDisconnected()
            emitFailureIfUserInitiated(intent, .protocolMismatch)
        case .refused:
            failRefusedOpen(conn, server: server, id: id, intent: intent, detail: resp.error)
        case let .granted(grant):
            await adoptGrant(grant, response: resp, conn: conn, server: server, pairingKey: pairingKey, intent: intent)
        }
    }

    private func putSession(server: DiscoveredServer, pairingKey: Data, controllers: [ControllerDescriptor]) async -> SessionResponse {
        let proof = SessionCrypto.hmacProofHex(pairingKey: pairingKey, deviceId: deviceId)
        return await http.putSession(
            ip: server.ip,
            port: server.httpPort,
            deviceId: deviceId,
            deviceName: deviceName,
            hmacProof: proof,
            controllers: controllers
        )
    }

    /// No usable key on disk: only a fresh user-initiated pair helps, so a
    /// silent attempt parks the row on "Needs pairing".
    private func failOpenWithoutKey(_ conn: WifiConnection, id: String, intent: ConnectIntent) {
        conn.markDisconnected()
        if intent != .userInitiated {
            markStale(id)
        }
        emitFailureIfUserInitiated(intent, .noSharedKey)
    }

    /// Down, moved or malformed. A TOFU mismatch aborted the handshake before
    /// any bytes flowed and is an identity problem no retry can outrun; a
    /// plain failure on a silent attempt re-enters the backoff curve.
    private func failRefusedOpen(_ conn: WifiConnection, server: DiscoveredServer, id: String, intent: ConnectIntent, detail: String?) {
        conn.markDisconnected()
        let identityChanged = pinMismatches.consume(server.ip)
        if identityChanged {
            emitFailureIfUserInitiated(intent, .identityChanged)
        } else if intent == .userInitiated {
            events.send(.failure(.sessionRefused(detail: detail)))
        } else {
            scheduleRetry(id)
        }
    }

    /// Derive the key, aim the socket, record the applied slot and go live.
    private func adoptGrant(
        _ grant: SessionGrant,
        response: SessionResponse,
        conn: WifiConnection,
        server: DiscoveredServer,
        pairingKey: Data,
        intent: ConnectIntent
    ) async {
        let id = conn.id
        guard let material = Self.sessionMaterial(tokenHex: grant.tokenHex, saltHex: grant.saltHex, pairingKey: pairingKey),
              let udpPort = UInt16(exactly: server.udpPort) else
        {
            conn.markDisconnected()
            emitFailureIfUserInitiated(intent, .badSessionMaterial)
            return
        }
        let client = SatelliteClient()
        let aimed = client.setConnectionParams(host: server.ip, udpPort: udpPort, token: material.token, sessionKey: material.key)
        guard aimed else {
            conn.markDisconnected()
            if intent == .userInitiated {
                events.send(.failure(.sessionLinkFailed))
            } else {
                scheduleRetry(id)
            }
            return
        }
        store.remember(server)
        clearStale(id)
        clearRetry(id)
        recordSlotOutcome(response, conn: conn)
        await fetchCatalog(id: id, server: server)
        conn.markConnected(client: client, connectionId: grant.connectionId, epoch: response.epoch, hooks: makeHooks(id: id))
    }

    /// Partial success is a 200: each requested slot reports its own apply
    /// result. The applied belief is recorded before `markConnected`, so the
    /// late-slot converge fires only for slots attached while linking.
    private func recordSlotOutcome(_ response: SessionResponse, conn: WifiConnection) {
        guard let slotId = conn.boundSlotId, let descriptor = conn.desiredDescriptor else { return }
        let applied = response.controllers.first { $0.ctrlIdx == descriptor.ctrlIdx }
        if applied?.slotIsLive == true {
            conn.markSlotApplied()
        } else {
            reportSlotNotApplied(slotId)
        }
    }

    private func reportSlotNotApplied(_ slotId: String) {
        events.send(.failure(.controllerNotApplied))
        slotRegistrationFailed.send(slotId)
    }

    // MARK: - Catalog

    /// Best-effort: an empty catalog (unreachable or pre-catalog satellite) is
    /// not cached, so the bound-slot default stays on the legacy type.
    func fetchCatalog(id: String, server: DiscoveredServer) async {
        await cacheCatalog(http.getCatalog(ip: server.ip, port: server.httpPort), for: id)
    }

    func cacheCatalog(_ catalog: CatalogDTO, for id: String) {
        guard !catalog.controllerTypes.isEmpty else { return }
        catalogs[id] = catalog
    }

    /// The type a freshly bound slot defaults to: the first type the
    /// satellite's catalog offers, else the legacy Xbox target.
    func defaultControllerType(for id: String) -> Int {
        catalogs[id]?.controllerTypes.first?.id ?? Int(ProtocolConstants.controllerTypeXbox)
    }

    // MARK: - Proactive re-key

    /// Re-PUT before the send counter can exhaust: the token, salt and key
    /// rotate and the counters restart on the same socket, so the hot path
    /// never blips. Failures stay silent; death and terminal-auth paths
    /// already report a satellite that is gone.
    func rekeySession(_ conn: WifiConnection) async {
        guard conn.hasLiveSession, let client = conn.client else { return }
        let id = conn.id
        let server = conn.server
        guard let pairingKey = pairingKeyData(for: id) else { return }
        let descriptors = conn.desiredDescriptor.map { [$0] } ?? []
        let resp = await putSession(server: server, pairingKey: pairingKey, controllers: descriptors)
        if resp.unauthorized || resp.verdict == .unauthorized {
            handleTerminalAuth(id, loud: false)
            return
        }
        applyRekey(resp, conn: conn, client: client, server: server, pairingKey: pairingKey)
    }

    /// A death and reconnect during the PUT's flight replaced the session;
    /// stale material must not re-arm the dead client.
    private func applyRekey(
        _ resp: SessionResponse,
        conn: WifiConnection,
        client: SatelliteClient,
        server: DiscoveredServer,
        pairingKey: Data
    ) {
        let sameSession = conn.hasLiveSession && conn.client === client
        guard sameSession,
              case let .granted(grant) = Self.classifyOpen(resp),
              let material = Self.sessionMaterial(tokenHex: grant.tokenHex, saltHex: grant.saltHex, pairingKey: pairingKey),
              let udpPort = UInt16(exactly: server.udpPort) else { return }
        client.setConnectionParams(host: server.ip, udpPort: udpPort, token: material.token, sessionKey: material.key)
        conn.setLastAppliedEpoch(resp.epoch)
    }

    // MARK: - Live slot converge

    /// Converge the bound slot of a live session over the per-controller
    /// routes: a descriptor is PUT whole without rotating the token; a
    /// detached slot is DELETEd and the session lives on.
    func syncBoundSlot(_ conn: WifiConnection) async {
        guard conn.hasLiveSession, let connectionId = conn.connectionId else { return }
        conn.setSlotSyncInFlight(true)
        defer { conn.setSlotSyncInFlight(false) }
        if let descriptor = conn.desiredDescriptor {
            await putBoundSlot(descriptor, conn: conn, connectionId: connectionId)
        } else {
            await deleteBoundSlot(conn: conn, connectionId: connectionId)
        }
    }

    private func putBoundSlot(_ descriptor: ControllerDescriptor, conn: WifiConnection, connectionId: String) async {
        let server = conn.server
        let resp = await http.putController(
            ip: server.ip,
            port: server.httpPort,
            connectionId: connectionId,
            deviceId: deviceId,
            hmacProof: proofFor(conn.id),
            descriptor: descriptor
        )
        if resp.unauthorized || resp.verdict == .unauthorized {
            handleTerminalAuth(conn.id, loud: false)
            return
        }
        if resp.controller?.slotIsLive == true {
            conn.markSlotApplied()
            conn.setLastAppliedEpoch(resp.epoch)
        } else if let slotId = conn.boundSlotId {
            reportSlotNotApplied(slotId)
        }
    }

    /// Best-effort: a failed DELETE self-heals through the enriched-ack
    /// reconcile or the next session PUT.
    private func deleteBoundSlot(conn: WifiConnection, connectionId: String) async {
        let server = conn.server
        _ = await http.deleteController(
            ip: server.ip,
            port: server.httpPort,
            connectionId: connectionId,
            ctrlIdx: WifiConnection.defaultCtrlIndex,
            deviceId: deviceId,
            hmacProof: proofFor(conn.id)
        )
    }
}
