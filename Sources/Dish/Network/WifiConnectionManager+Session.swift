// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// Session lifecycle for `WifiConnectionManager` (contract §Session /
// §Crypto): the declarative `PUT /api/connections` that opens or converges a
// session, the HKDF session-key handoff to the UDP client (the pairing key
// never reaches the data plane), the proactive re-key before send-counter
// exhaustion (gap G4), and the live per-slot converge over the standalone
// controller routes (gap G8's REST side driving the W2-B data plane). Split
// from the manager core the same way the pairing flows are.

import CryptoKit
import DishCore
import Foundation

extension WifiConnectionManager {

    /// Delay before the alive-poll's onDead path attempts a silent reconnect.
    /// Short enough that a momentary Wi-Fi drop self-heals before the user
    /// navigates away in frustration; long enough that a real outage doesn't
    /// burn the satellite's TCP/UDP buffers with back-to-back retries. The
    /// retry path uses `.retryAfterDeath` so it's silent on failure.
    static let autoRetryBackoffNs: UInt64 = 1_500_000_000

    /// Parse a session PUT response's token + salt hex and derive the session
    /// key: `HKDF-SHA256(pairingKey, sessionSalt, "satellite-session-v1" ‖
    /// token BE)` — both the fresh-session and re-key paths share this. Nil
    /// on malformed material (a pre-protocol-1 server).
    nonisolated static func sessionMaterial(
        tokenHex: String,
        saltHex: String,
        pairingKey: Data
    ) -> (token: UInt32, key: SymmetricKey)? {
        guard let tokenData = hexToBytes(tokenHex), tokenData.count == 4,
              let saltData = hexToBytes(saltHex),
              saltData.count == ProtocolConstants.sessionSaltSize else { return nil }
        let token = tokenData.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        let key = SessionCrypto.deriveSessionKey(
            pairingKey: pairingKey,
            salt: saltData,
            token: token
        )
        return (token, key)
    }

    // MARK: - Open / converge

    /// Open (or converge) the protocol-1 session: one declarative
    /// `PUT /api/connections` carrying the full desired controller set + the
    /// hmacProof, then HKDF the session key from (pairingKey, response salt,
    /// response token) — the pairing key itself never touches the UDP path
    /// (contract §Crypto; gaps G6/G8).
    func openSession(
        conn: WifiConnection,
        server: DiscoveredServer,
        intent: ConnectIntent
    ) async {
        let id = WifiConnection.idFor(server)
        guard let pairingKey = pairingKeyData(for: id) else {
            conn.markDisconnected()
            // Silent retry / cold-launch reconnect with no usable key on
            // disk: the only useful next step is a fresh user-initiated
            // pair, so mark the row "Needs pairing" until that happens.
            // User-initiated callers already get the explicit banner.
            if intent != .userInitiated {
                markStale(id)
            }
            emitErrorIfUserInitiated(intent, "No shared key — re-pair needed")
            return
        }
        let proof = SessionCrypto.hmacProofHex(pairingKey: pairingKey, deviceId: deviceId)

        // The declarative PUT carries the WHOLE desired controller set (empty
        // is a valid zero-controller session — a user sitting in menus).
        let descriptors: [ControllerDescriptor] = conn.desiredDescriptor.map { [$0] } ?? []

        let resp = await http.putSession(
            ip: server.ip,
            port: server.httpPort,
            deviceId: deviceId,
            deviceName: deviceName,
            hmacProof: proof,
            controllers: descriptors
        )
        if resp.unauthorized || resp.httpStatus == 401 {
            // NOT_PAIRED / BAD_PROOF: the satellite revoked our trust —
            // terminal (contract §hmacProof).
            handleTerminalAuth(id, loud: intent == .userInitiated)
            return
        }
        if resp.httpStatus == 409 {
            conn.markDisconnected()
            emitErrorIfUserInitiated(intent, Self.protocolMismatchMessage)
            return
        }
        guard resp.reachable,
              let connId = resp.connectionId,
              let tokenHex = resp.token,
              let saltHex = resp.sessionSalt else
        {
            conn.markDisconnected()
            emitErrorIfUserInitiated(intent, "Error: \(resp.error ?? "connection failed")")
            return
        }
        // sessionKey = HKDF(pairingKey, salt, token) — derived here in the
        // control plane; the client below only ever sees the SESSION key.
        guard let material = Self.sessionMaterial(
            tokenHex: tokenHex,
            saltHex: saltHex,
            pairingKey: pairingKey
        ), let udpPort = UInt16(exactly: server.udpPort) else {
            conn.markDisconnected()
            emitErrorIfUserInitiated(intent, "Bad token from server")
            return
        }

        let client = SatelliteClient()
        guard client.setConnectionParams(
            host: server.ip,
            udpPort: udpPort,
            token: material.token,
            sessionKey: material.key
        ) else {
            conn.markDisconnected()
            return
        }
        store.remember(server)
        // Successful authenticated session: any "Needs pairing" marker we
        // set on a prior failed silent retry no longer applies. Clearing
        // here (rather than in the caller) covers all three intents —
        // userInitiated, autoReconnect, retryAfterDeath — uniformly.
        clearStale(id)

        // Surface each requested slot's apply outcome from the PUT itself
        // (partial success is a 200 — contract §Error model).
        if let slotId = conn.boundSlotId {
            for descriptor in descriptors {
                let applied = resp.controllers.first { $0.ctrlIdx == descriptor.ctrlIdx }
                if applied?.slotIsLive != true {
                    events.send(.error("Server could not apply the controller"))
                    slotRegistrationFailed.send(slotId)
                }
            }
        }
        conn.markConnected(client: client, connectionId: connId) { [weak self] in
            // Heartbeats stopped. The alive-poll already flipped the wire
            // state to `.stale` before invoking us; tear down the dead
            // session and kick a short-backoff silent reconnect attempt
            // using the saved shared key. If the satellite is just
            // momentarily unreachable (Wi-Fi roam, brief drop) the chip
            // glides Online → Connecting… → Online without a banner. If
            // the outage persists, the silent retry fails and the chip
            // lands on `.saved` / `.ready` — still no banner, because the
            // user didn't ask for this attempt. Ports
            // `SatelliteConnectionManager.kt` AUTO_RETRY_BACKOFF_MS.
            guard let self else { return }
            let staleServer = server
            self.disconnect(id: conn.id)
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: Self.autoRetryBackoffNs)
                guard let self else { return }
                if self.connections[conn.id]?.state == .idle {
                    self.connect(to: staleServer, intent: .retryAfterDeath)
                }
            }
        }
    }

    // MARK: - Proactive re-key (gap G4)

    /// Re-PUT the session before the send counter can exhaust (contract
    /// §Crypto: counters never wrap; clients SHOULD re-PUT past 0xF0000000).
    /// The PUT rotates token/salt, the key re-derives, and
    /// `setConnectionParams` restarts the counters at 1 on the SAME socket —
    /// the hot path never blips. Failures stay silent: a dead/unpaired
    /// satellite is already surfacing through the heartbeat/terminal-auth
    /// paths, and a session that truly exhausts goes silent and self-heals
    /// via the death-retry re-PUT.
    func rekeySession(_ conn: WifiConnection) async {
        guard conn.state == .live, let client = conn.client else { return }
        let id = conn.id
        let server = conn.server
        guard let pairingKey = pairingKeyData(for: id) else { return }
        let proof = SessionCrypto.hmacProofHex(pairingKey: pairingKey, deviceId: deviceId)
        let descriptors: [ControllerDescriptor] = conn.desiredDescriptor.map { [$0] } ?? []

        let resp = await http.putSession(
            ip: server.ip,
            port: server.httpPort,
            deviceId: deviceId,
            deviceName: deviceName,
            hmacProof: proof,
            controllers: descriptors
        )
        if resp.unauthorized || resp.httpStatus == 401 {
            handleTerminalAuth(id, loud: false)
            return
        }
        guard conn.state == .live,
              resp.reachable,
              let tokenHex = resp.token,
              let saltHex = resp.sessionSalt,
              let material = Self.sessionMaterial(
                  tokenHex: tokenHex,
                  saltHex: saltHex,
                  pairingKey: pairingKey
              ),
              let udpPort = UInt16(exactly: server.udpPort) else { return }
        client.setConnectionParams(
            host: server.ip,
            udpPort: udpPort,
            token: material.token,
            sessionKey: material.key
        )
    }

    // MARK: - Live slot converge (contract §Controller)

    /// Converge the bound slot of a LIVE session over the standalone
    /// controller routes: descriptor present → `PUT .../controllers/{idx}`
    /// (whole descriptor, no token rotation); bound slot gone → `DELETE`
    /// (removes the SLOT only; the session lives on). Sessions that are not
    /// live converge through the next session PUT instead.
    func syncBoundSlot(_ conn: WifiConnection) async {
        guard conn.state == .live, let cid = conn.connectionId else { return }
        let server = conn.server
        let proof = proofFor(conn.id)
        conn.setSlotSyncInFlight(true)
        defer { conn.setSlotSyncInFlight(false) }

        if let descriptor = conn.desiredDescriptor {
            let resp = await http.putController(
                ip: server.ip,
                port: server.httpPort,
                connectionId: cid,
                deviceId: deviceId,
                hmacProof: proof,
                descriptor: descriptor
            )
            if resp.unauthorized || resp.httpStatus == 401 {
                handleTerminalAuth(conn.id, loud: false)
                return
            }
            // Apply outcome: replugFailed leaves the previous pad live —
            // streams keep flowing; every other non-ok code means the slot
            // is not plugged (partial success is a 200).
            if resp.controller?.slotIsLive != true, let slotId = conn.boundSlotId {
                events.send(.error("Server could not apply the controller"))
                slotRegistrationFailed.send(slotId)
            }
        } else {
            // Detach: best-effort. A failed DELETE self-heals via the
            // enriched-ack reconcile (W3-A) or the next session PUT.
            _ = await http.deleteController(
                ip: server.ip,
                port: server.httpPort,
                connectionId: cid,
                ctrlIdx: WifiConnection.defaultCtrlIndex,
                deviceId: deviceId,
                hmacProof: proof
            )
        }
    }
}
