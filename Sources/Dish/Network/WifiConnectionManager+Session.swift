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
        // Outcome classification rides DishCore's error-model reducer
        // (`RestStamped.verdict` → `classifyRest`); the code-based
        // `unauthorized` stays as the dish-linux-parity belt for a terminal
        // machine code on a non-401 status.
        if resp.unauthorized || resp.verdict == .unauthorized {
            // NOT_PAIRED / BAD_PROOF: the satellite revoked our trust —
            // terminal (contract §hmacProof).
            handleTerminalAuth(id, loud: intent == .userInitiated)
            return
        }
        if resp.verdict == .versionMismatch {
            conn.markDisconnected()
            emitErrorIfUserInitiated(intent, Self.protocolMismatchMessage)
            return
        }
        guard resp.reachable,
              let connId = resp.connectionId,
              let tokenHex = resp.token,
              let saltHex = resp.sessionSalt else
        {
            // Down / moved / malformed-core response. Loud only for the
            // user; silent intents re-enter the backoff curve so the next
            // attempt rides `backoffDelayMs` instead of a fixed period
            // (gap G14; mirrors dish-linux openSession).
            conn.markDisconnected()
            if pinMismatches.consume(server.ip) {
                // A TOFU mismatch aborts the handshake pre-request (zero
                // bytes flowed) and lands here as a transport failure. It is
                // an identity problem, not a connectivity one: surface the
                // honest message instead of the generic failure, and do NOT
                // arm the backoff curve — no retry can outrun a changed
                // identity; only the user (re-pair / forget) can. Mirrors
                // dish-android's keyed-path `failSession(...,
                // IDENTITY_CHANGED_MSG, retry = false)` and the pair paths'
                // `unreachableMessage` consume (gap G7 UX parity).
                emitErrorIfUserInitiated(intent, Self.identityChangedMessage)
            } else if intent == .userInitiated {
                events.send(.error("Error: \(resp.error ?? "connection failed")"))
            } else {
                scheduleRetry(id)
            }
            return
        }
        // sessionKey = HKDF(pairingKey, salt, token) — derived here in the
        // control plane; the client below only ever sees the SESSION key.
        guard let material = Self.sessionMaterial(
            tokenHex: tokenHex,
            saltHex: saltHex,
            pairingKey: pairingKey
        ), let udpPort = UInt16(exactly: server.udpPort) else {
            // Protocol garbage, not an outage — retrying the same request
            // can't help, so no backoff entry (dish-linux parity).
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
            if intent != .userInitiated { scheduleRetry(id) }
            return
        }
        store.remember(server)
        // Successful authenticated session: any "Needs pairing" marker we
        // set on a prior failed silent retry no longer applies, and the
        // backoff curve resets. Clearing here (rather than in the caller)
        // covers all three intents uniformly.
        clearStale(id)
        clearRetry(id)

        // Surface each requested slot's apply outcome from the PUT itself
        // (partial success is a 200 — contract §Error model), and record the
        // applied belief BEFORE markConnected so its late-slot converge only
        // fires for slots attached while the session was still linking.
        var slotLiveInPut = false
        if let slotId = conn.boundSlotId {
            for descriptor in descriptors {
                let applied = resp.controllers.first { $0.ctrlIdx == descriptor.ctrlIdx }
                if applied?.slotIsLive == true {
                    slotLiveInPut = true
                } else {
                    events.send(.error("Server could not apply the controller"))
                    slotRegistrationFailed.send(slotId)
                }
            }
        }
        if slotLiveInPut {
            conn.markSlotApplied()
        }
        conn.markConnected(
            client: client,
            connectionId: connId,
            epoch: resp.epoch,
            hooks: makeHooks(id: conn.id)
        )
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
        // Faltering still counts as live here: REST may be perfectly healthy
        // while UDP acks are lossy, and bailing mid-re-key after the server
        // rotated the token would orphan the session.
        guard conn.state == .live || conn.state == .faltering, let client = conn.client else { return }
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
        if resp.unauthorized || resp.verdict == .unauthorized {
            handleTerminalAuth(id, loud: false)
            return
        }
        // `conn.client === client`: a death+reconnect during the PUT flight
        // replaced the session — applying the stale material would re-arm the
        // dead client and stamp a stale epoch onto the new session.
        guard conn.state == .live || conn.state == .faltering,
              conn.client === client,
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
        // The re-PUT is an applied-topology change server-side — adopt its
        // epoch so the next enriched ack doesn't read as drift (gap G9).
        conn.setLastAppliedEpoch(resp.epoch)
    }

    // MARK: - Live slot converge (contract §Controller)

    /// Converge the bound slot of a LIVE session over the standalone
    /// controller routes: descriptor present → `PUT .../controllers/{idx}`
    /// (whole descriptor, no token rotation); bound slot gone → `DELETE`
    /// (removes the SLOT only; the session lives on). Sessions that are not
    /// live converge through the next session PUT instead.
    func syncBoundSlot(_ conn: WifiConnection) async {
        guard conn.state == .live || conn.state == .faltering,
              let cid = conn.connectionId else { return }
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
            if resp.unauthorized || resp.verdict == .unauthorized {
                handleTerminalAuth(conn.id, loud: false)
                return
            }
            // Apply outcome: replugFailed leaves the previous pad live —
            // streams keep flowing; every other non-ok code means the slot
            // is not plugged (partial success is a 200).
            if resp.controller?.slotIsLive == true {
                // Applied belief + epoch adoption for the reconcile compare
                // (dish-linux registerController callback; gap G9).
                conn.markSlotApplied()
                conn.setLastAppliedEpoch(resp.epoch)
            } else if let slotId = conn.boundSlotId {
                events.send(.error("Server could not apply the controller"))
                slotRegistrationFailed.send(slotId)
            }
        } else {
            // Detach: best-effort. A failed DELETE self-heals via the
            // enriched-ack reconcile or the next session PUT.
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
