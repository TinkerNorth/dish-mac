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
        /// 409 with the satellite's range (0 for a bound the body lacked).
        case versionMismatch(supported: Int, supportedMin: Int)
        case refused
        case granted(SessionGrant)
    }

    /// Classify a session PUT response. The terminal 401 and the 409 come
    /// first; a reachable reply with the three grant fields is a grant;
    /// anything else is a refusal.
    nonisolated static func classifyOpen(_ resp: SessionResponse) -> OpenOutcome {
        let unauthorized = resp.unauthorized || resp.verdict == .unauthorized
        if unauthorized { return .unauthorized }
        if resp.verdict == .versionMismatch {
            return .versionMismatch(supported: resp.supportedProtocol, supportedMin: resp.supportedProtocolMin)
        }
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
        await readCatalogIfUnread(id: id, server: server)
        await readCapabilitiesIfUnread(id: id, server: server)
        refreshControllerType(conn, id: id)
        let descriptors = conn.desiredDescriptor.map { [$0] } ?? []
        let resp = await putSession(
            server: server,
            pairingKey: pairingKey,
            controllers: descriptors,
            protocolVersion: conn.offeredProtocolVersion,
            mouseControl: conn.wantsMouseControl
        )
        switch Self.classifyOpen(resp) {
        case .unauthorized:
            handleTerminalAuth(id, loud: intent == .userInitiated)
        case let .versionMismatch(supported, supportedMin):
            if lowerOfferOrFail(conn, intent: intent, supported: supported, supportedMin: supportedMin) {
                await openSession(conn: conn, server: server, intent: intent)
            }
        case .refused:
            failRefusedOpen(conn, server: server, id: id, intent: intent, detail: resp.error)
        case let .granted(grant):
            await adoptGrant(grant, response: resp, conn: conn, server: server, pairingKey: pairingKey, intent: intent)
        }
    }

    private func putSession(
        server: DiscoveredServer,
        pairingKey: Data,
        controllers: [ControllerDescriptor],
        protocolVersion: Int,
        mouseControl: Bool
    ) async -> SessionResponse {
        let proof = SessionCrypto.hmacProofHex(pairingKey: pairingKey, deviceId: deviceId)
        return await http.putSession(
            ip: server.ip,
            port: server.httpPort,
            deviceId: deviceId,
            deviceName: deviceName,
            hmacProof: proof,
            controllers: controllers,
            protocolVersion: protocolVersion,
            mouseControl: mouseControl
        )
    }

    // MARK: - Version negotiation (contract §Versioning)

    /// What a 409's range leaves of an attempt.
    enum OfferStep: Equatable {
        /// The lower offer now stored on the connection may go on.
        case retryLower
        /// The attempt is over and the row's chip says which end must update.
        case failed(ConnectionFailure)
    }

    /// Reads a 409's range. A satellite that repeats a range it already
    /// rejected us at cannot lower the offer further and reads as unreadable.
    func settleOffer(_ conn: WifiConnection, supported: Int, supportedMin: Int) -> OfferStep {
        let outcome = settleRejected(supported: supported, supportedMin: supportedMin)
        if outcome.verdict == .retryLower, outcome.settledVersion < conn.offeredProtocolVersion {
            conn.setOfferedProtocolVersion(outcome.settledVersion)
            return .retryLower
        }
        conn.setProtocolCompat(compatForOutcome(outcome))
        conn.markDisconnected()
        return .failed(Self.versionFailure(for: outcome.verdict))
    }

    /// True when the attempt may go on with the lower offer; false when it
    /// is over and the failure is reported.
    func lowerOfferOrFail(_ conn: WifiConnection, intent: ConnectIntent, supported: Int, supportedMin: Int) -> Bool {
        switch settleOffer(conn, supported: supported, supportedMin: supportedMin) {
        case .retryLower:
            return true
        case let .failed(failure):
            emitFailureIfUserInitiated(intent, failure)
            return false
        }
    }

    /// The failure a 409 surfaces once the attempt is over.
    nonisolated static func versionFailure(for verdict: ProtocolVerdict) -> ConnectionFailure {
        switch verdict {
        case .updateDish: .dishUpdateRequired
        case .updateSatellite: .satelliteUpdateRequired
        case .unusable, .retryLower, .settled: .protocolMismatch
        }
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
        // The SETTLED version, never the offer: a pre-versioning satellite
        // echoes 1 whatever was asked, and the 0x000C shape follows the echo.
        let negotiated = settleAccepted(echoedVersion: response.protocolVersion)
        let client = SatelliteClient()
        let aimed = client.setConnectionParams(
            host: server.ip,
            udpPort: udpPort,
            token: material.token,
            sessionKey: material.key,
            protocolVersion: negotiated.settledVersion
        )
        guard aimed else {
            conn.markDisconnected()
            if intent == .userInitiated {
                events.send(.failure(.sessionLinkFailed))
            } else {
                scheduleRetry(id)
            }
            return
        }
        conn.adoptProtocol(negotiated)
        store.remember(server)
        clearStale(id)
        clearRetry(id)
        recordSlotOutcome(response, conn: conn)
        conn.setMouseControlGranted(response.mouseControl.granted)
        await fetchCatalog(id: id, server: server)
        await fetchCapabilities(id: id, server: server)
        conn.markConnected(client: client, connectionId: grant.connectionId, epoch: response.epoch, hooks: makeHooks(id: id))
    }

    /// Partial success is a 200: each requested slot reports its own apply
    /// result. The applied belief is recorded before `markConnected`, so the
    /// late-slot converge fires only for slots attached while linking.
    private func recordSlotOutcome(_ response: SessionResponse, conn: WifiConnection) {
        guard let slotId = conn.boundSlotId, let descriptor = conn.desiredDescriptor else { return }
        let applied = response.controllers.first { $0.ctrlIdx == descriptor.ctrlIdx }
        if let applied, applied.slotIsLive {
            conn.markSlotApplied()
            recordMotionStatus(applied, connectionId: conn.id, slotId: slotId)
        } else {
            reportSlotNotApplied(slotId)
        }
    }

    /// The satellite's word on motion for the binding it just applied.
    private func recordMotionStatus(_ applied: ControllerApplyDto, connectionId: String, slotId: String) {
        motionStatus.setStatus(
            MotionBackendStatus(sinkSupportedForType: applied.motionSinkSupportedForType, backendOk: applied.motionBackendOk),
            for: SlotKey(connectionId: connectionId, slotId: slotId)
        )
    }

    /// The descriptor's type is resolved as the PUT is built, against the
    /// newest catalog and the user's pick, so a first contact already
    /// emulates the pad as itself. Never a re-send: the session is not live.
    /// The type, and the catalog's word on that type's touchpad, which the
    /// descriptor's mode reads.
    private func refreshControllerType(_ conn: WifiConnection, id: String) {
        guard let slotId = conn.boundSlotId else { return }
        let type = resolveControllerType(for: id, slotId: slotId, family: conn.boundFamily)
        conn.setControllerType(type)
        var facts = conn.touchpadFacts
        facts.typeOffersDs4 = typeOffersDs4Touchpad(in: catalogs[id], type: type)
        conn.setTouchpadFacts(facts)
    }

    /// The probe is unauthenticated, so a satellite never probed is asked
    /// once before the first PUT: the descriptor's mouse rung reads it.
    private func readCapabilitiesIfUnread(id: String, server: DiscoveredServer) async {
        guard capabilities[id] == nil else { return }
        await fetchCapabilities(id: id, server: server)
    }

    /// The catalog is unauthenticated, so a satellite never seen before is
    /// asked once before the first PUT; the refresh after the grant keeps it
    /// current for the sessions that follow.
    private func readCatalogIfUnread(id: String, server: DiscoveredServer) async {
        guard catalogs[id] == nil else { return }
        await fetchCatalog(id: id, server: server)
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

    /// The type a freshly bound pad is emulated as: the catalog type that
    /// emulates the pad's own family, else the first type offered, else the
    /// legacy Xbox target.
    func defaultControllerType(for id: String, family: PadFamily = .other) -> Int {
        preferredControllerType(in: catalogs[id], for: family)
    }

    /// The type a bound pad is emulated as: the user's pick for this binding,
    /// else the family's own type from the catalog.
    func resolveControllerType(for id: String, slotId: String, family: PadFamily) -> Int {
        emulatedControllerType(
            override: typeOverrides.typeFor(SlotKey(connectionId: id, slotId: slotId)),
            catalog: catalogs[id],
            family: family
        )
    }

    // MARK: - Capabilities probe

    /// Best-effort, like the catalog: an unreachable or pre-probe satellite
    /// leaves no entry.
    func fetchCapabilities(id: String, server: DiscoveredServer) async {
        await cacheCapabilities(http.getCapabilities(ip: server.ip, port: server.httpPort), for: id)
    }

    func cacheCapabilities(_ probe: ServerCapabilitiesDTO, for id: String) {
        guard probe.reachable else { return }
        capabilities[id] = probe
        guard let conn = connections[id] else { return }
        conn.setHostAudio(probe.audioVerdict)
        var facts = conn.touchpadFacts
        facts.hostMouseControl = probe.host.mouseControl.supported && probe.host.mouseControl.available
        conn.setTouchpadFacts(facts)
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
        let resp = await putSession(
            server: server,
            pairingKey: pairingKey,
            controllers: descriptors,
            protocolVersion: conn.offeredProtocolVersion,
            mouseControl: conn.wantsMouseControl
        )
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
        let negotiated = settleAccepted(echoedVersion: resp.protocolVersion)
        client.setConnectionParams(
            host: server.ip,
            udpPort: udpPort,
            token: material.token,
            sessionKey: material.key,
            protocolVersion: negotiated.settledVersion
        )
        conn.adoptProtocol(negotiated)
        conn.setLastAppliedEpoch(resp.epoch)
        conn.setMouseControlGranted(resp.mouseControl.granted)
    }

    // MARK: - Live slot converge

    /// Converge the bound slot of a live session over the per-controller
    /// routes: a descriptor is PUT whole without rotating the token; a
    /// detached slot is DELETEd and the session lives on.
    func syncBoundSlot(_ conn: WifiConnection) async {
        guard conn.hasLiveSession, let connectionId = conn.connectionId else { return }
        conn.setSlotSyncInFlight(true)
        defer { conn.setSlotSyncInFlight(false) }
        refreshControllerType(conn, id: conn.id)
        if let descriptor = conn.desiredDescriptor {
            await putBoundSlot(descriptor, conn: conn, connectionId: connectionId)
        } else {
            await deleteBoundSlot(conn: conn, connectionId: connectionId)
        }
        await convergeHostFeatures(conn)
    }

    /// The grant is computed only at the session PUT (contract
    /// §hostFeatures), so a pick that changed the session's desire rides a
    /// whole PUT through the re-key path: the token rotates on the same
    /// socket and the hot path never blips.
    private func convergeHostFeatures(_ conn: WifiConnection) async {
        guard conn.hasLiveSession, conn.wantsMouseControl != conn.mouseControlGranted else { return }
        await rekeySession(conn)
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
        if let controller = resp.controller, controller.slotIsLive {
            conn.markSlotApplied()
            conn.setLastAppliedEpoch(resp.epoch)
            if let slotId = conn.boundSlotId {
                recordMotionStatus(controller, connectionId: conn.id, slotId: slotId)
            }
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
