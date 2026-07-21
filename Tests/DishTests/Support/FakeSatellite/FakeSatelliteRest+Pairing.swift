// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 Dish contributors.
//
// FakeSatellite pairing routes (contract §Pairing): operator-PIN path A,
// client-PIN path B + status poll, proof-gated rotation and self-unpair.
// Split from FakeSatelliteRest the same way the app splits its manager.

import Foundation
import Network

extension FakeSatelliteRest {

    // MARK: - Pairing (contract §Pairing)

    func pair(_ request: FakeSatelliteHttp.Request, on connection: NWConnection) -> FakeSatelliteHttp.Response? {
        let response = pairResponse(request)
        let held = store.with { state -> Bool in
            guard state.holdNextPair else { return false }
            state.holdNextPair = false
            state.heldPairs += 1
            return true
        }
        if held {
            heldLock.lock()
            heldPair = (connection, FakeSatelliteHttp.serialize(response))
            heldLock.unlock()
            return nil
        }
        return response
    }

    func pairResponse(_ request: FakeSatelliteHttp.Request) -> FakeSatelliteHttp.Response {
        let body = FakeSatelliteHttp.parseJSON(request.body)
        if let rejection = versionRejection(body) { return rejection }
        let deviceId = body["deviceId"] as? String ?? ""
        let deviceName = body["deviceName"] as? String ?? ""
        if let rotated = rotateIfProofValid(body, deviceId: deviceId, deviceName: deviceName) { return rotated }
        let pin = body["pin"] as? String ?? ""
        let clientPin = body["clientPin"] as? String ?? ""
        if !pin.isEmpty, pin == operatorPin {
            let minted = FakeSatelliteRandom.hex(32)
            store.with { state in
                state.pairingKeyHex = minted
                state.pairedDeviceId = deviceId
                state.pairedDeviceName = deviceName
            }
            return FakeSatelliteHttp.json(200, [
                "ok": true,
                "message": "paired successfully",
                "sharedKey": minted,
                "protocolVersion": 1
            ])
        }
        if !clientPin.isEmpty {
            store.with { state in
                state.lastClientPin = clientPin
                state.clientPinDenied = false
                if state.pairedDeviceId == nil { state.pairedDeviceId = deviceId }
            }
            return FakeSatelliteHttp.json(200, ["ok": false, "pending": true, "message": "awaiting approval on the satellite"])
        }
        // Wrong AND empty PIN both land on the real route's terminal arm:
        // 200 `{"ok":false,...}` (routes_client.cpp pairRoute), never 400.
        return FakeSatelliteHttp.json(200, ["ok": false, "error": "invalid or expired PIN"])
    }

    /// Key rotation: a valid hmacProof against the CURRENT key re-mints the
    /// key (closing any live session with reason `replaced` first); a failed
    /// proof falls through to the PIN paths (contract §Pairing Update).
    /// Device-scoped like the real route (the row is looked up by deviceId).
    func rotateIfProofValid(_ body: [String: Any], deviceId: String, deviceName: String) -> FakeSatelliteHttp.Response? {
        guard let proof = body["hmacProof"] as? String,
              let keyHex = store.with({ $0.pairingKeyHex }),
              let key = FakeSatelliteCrypto.hexToData(keyHex),
              store.with({ $0.pairedDeviceId }).map({ $0 == deviceId }) ?? true,
              FakeSatelliteCrypto.verifyHmacProof(pairingKey: key, deviceId: deviceId, proofHex: proof) else
        {
            return nil
        }
        let minted = FakeSatelliteRandom.hex(32)
        let closeTarget = store.with { state -> FakeSatelliteSession? in
            let live = state.activeToken.flatMap { state.sessions[$0] }
            state.sessions.removeAll()
            state.activeToken = nil
            state.pairingKeyHex = minted
            state.pairedDeviceId = deviceId
            state.pairedDeviceName = deviceName
            return live
        }
        if let closeTarget { udp.sendClose(.replaced, to: closeTarget) }
        return FakeSatelliteHttp.json(200, [
            "ok": true,
            "message": "key rotated",
            "sharedKey": minted,
            "protocolVersion": 1
        ])
    }

    /// Path-B poll: pending until `approveClientPin()` stages a key, which is
    /// then handed back exactly once (single-use staged key, per contract).
    func pairStatus(_ request: FakeSatelliteHttp.Request) -> FakeSatelliteHttp.Response {
        store.with { state -> FakeSatelliteHttp.Response in
            state.pairStatusPolls += 1
            if let staged = state.stagedApprovalKeyHex {
                state.stagedApprovalKeyHex = nil
                state.pairingKeyHex = staged
                state.lastClientPin = nil // request fulfilled; later polls report none
                if state.pairedDeviceId == nil { state.pairedDeviceId = request.query["deviceId"] }
                return FakeSatelliteHttp.json(200, ["ok": true, "status": "approved", "sharedKey": staged])
            }
            if state.clientPinDenied {
                return FakeSatelliteHttp.json(200, ["ok": false, "status": "denied"])
            }
            if state.lastClientPin != nil {
                return FakeSatelliteHttp.json(200, ["ok": false, "status": "pending"])
            }
            return FakeSatelliteHttp.json(200, ["ok": false, "status": "none"])
        }
    }

    /// Client self-unpair; closes any live session with reason `unpaired`
    /// first (contract §Pairing Delete).
    func selfUnpair(_ request: FakeSatelliteHttp.Request) -> FakeSatelliteHttp.Response {
        let body = FakeSatelliteHttp.parseJSON(request.body)
        switch authenticate(request, body: body) {
        case let .unauthorized(code):
            return unauthorized(code)
        case let .ok(deviceId):
            let closeTarget = store.with { state -> FakeSatelliteSession? in
                state.unpairCalls.append(deviceId)
                let live = state.activeToken.flatMap { state.sessions[$0] }
                state.pairingKeyHex = nil
                state.pairedDeviceId = nil
                state.pairedDeviceName = nil
                state.sessions.removeAll()
                state.activeToken = nil
                state.controllers = []
                return live
            }
            if let closeTarget { udp.sendClose(.unpaired, to: closeTarget) }
            return FakeSatelliteHttp.json(200, ["ok": true])
        }
    }
}
